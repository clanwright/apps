{
  lib,
  pkgs,
  config,
  tools,
  appsPkgs,
  settings,
  serviceController ? "${pkgs.systemd}/bin/systemctl",
  appDirectory ? builtins.head config.clan.core.state.vaultwarden-app.folders,
  nativePre ? config.clan.core.state."${settings.database.name}-db".preBackupScript,
  nativePost ? config.clan.core.state."${settings.database.name}-db".postBackupScript,
  stagedDump ? "${
    builtins.head config.clan.core.state."${settings.database.name}-db".folders
  }/pg-dump",
  lockPath ? "/run/lock/apps-vaultwarden-recovery.lock",
}:
let
  database = settings.database.name;
  formatVersion = "vaultwarden-pg18-files-v1";
  marker = pkgs.writeText "vaultwarden-recovery-format" "${formatVersion}\n";
  postgres = appsPkgs.postgresql_18;
  check = lib.getExe (
    pkgs.writeShellApplication {
      name = "check-vaultwarden-recovery";
      runtimeInputs = [
        postgres
        pkgs.coreutils
        pkgs.findutils
        pkgs.gnugrep
      ];
      text = ''
        # The public PostgreSQL helper deliberately clears the environment.
        # Its callback reads only this path from the same private scratch mount.
        input=$(cat /tmp/apps-vaultwarden-recovery-context/input-path)
        app="$input/vaultwarden-app"
        test -d "$app"
        test ! -L "$app"
        test -z "$(find "$app" \( ! -type f -a ! -type d \) -print -quit)"

        # Empty installations are valid, but the Vaultwarden tables and every
        # surviving attachment's cipher and on-disk bytes must be present.
        psql -X -v ON_ERROR_STOP=1 -A -t -c "SELECT CASE WHEN to_regclass('public.ciphers') IS NOT NULL AND to_regclass('public.attachments') IS NOT NULL THEN 1 ELSE 0 END" | grep -qx 1
        psql -X -v ON_ERROR_STOP=1 -A -t -c "SELECT count(*) FROM ciphers c LEFT JOIN users u ON u.uuid = c.user_uuid LEFT JOIN organizations o ON o.uuid = c.organization_uuid WHERE (c.user_uuid IS NULL AND c.organization_uuid IS NULL) OR (c.user_uuid IS NOT NULL AND u.uuid IS NULL) OR (c.organization_uuid IS NOT NULL AND o.uuid IS NULL)" | grep -qx 0
        psql -X -v ON_ERROR_STOP=1 -A -t -c "SELECT count(*) FROM attachments a LEFT JOIN ciphers c ON c.uuid = a.cipher_uuid WHERE c.uuid IS NULL" | grep -qx 0
        psql -X -v ON_ERROR_STOP=1 -A -t -F ' ' -c "SELECT a.cipher_uuid, a.id, a.file_size FROM attachments a ORDER BY a.id" > /tmp/vaultwarden-attachments.list
        while IFS=' ' read -r cipher attachment expected_size; do
          test -n "$cipher" && test -n "$attachment" && test -n "$expected_size"
          case "$cipher" in *[!a-fA-F0-9-]*) exit 1 ;; esac
          case "$attachment" in *[!a-fA-F0-9-]*) exit 1 ;; esac
          case "$expected_size" in *[!0-9]*) exit 1 ;; esac
          file="$app/attachments/$cipher/$attachment"
          if ! test -f "$file" || test -L "$file"; then
            echo 'Vaultwarden recovery: attachment record has no stored file; incomplete upload or missing data' >&2
            exit 1
          fi
          test "$(stat -c %s "$file")" = "$expected_size"
        done < /tmp/vaultwarden-attachments.list
      '';
    }
  );
  validator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    inherit database;
    checkCommand = check;
  };
  capture = lib.getExe (
    pkgs.writeShellApplication {
      name = "capture-vaultwarden-recovery";
      excludeShellChecks = [ "SC2016" ]; # Native Clan shell snippets are intentionally quoted for bash -c.
      runtimeInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.util-linux
      ];
      text = ''
        test "$#" -eq 1
        output=$1
        case "$output" in /*) ;; *) exit 1 ;; esac
        test -d "$output" && test ! -L "$output"
        test "$(stat -c %u "$output")" = "$(id -u)"
        test "$(stat -c %a "$output")" = 700
        test -z "$(find "$output" -mindepth 1 -print -quit)"

        # The lock also serializes this producer's concurrent captures. Other
        # native PostgreSQL staging callers require the same outer serializer.
        exec 9>${lib.escapeShellArg lockPath}
        flock -x 9
        child=""
        pre_attempted=0
        restart_needed=0
        finished=0
        run_step() {
          setsid "$@" &
          child=$!
          local result=0
          wait "$child" || result=$?
          if ! kill -0 "$child" 2>/dev/null; then child=""; fi
          return "$result"
        }
        cleanup() {
          local status=$?
          trap - EXIT
          trap : HUP INT TERM
          if [ -n "$child" ]; then
            kill -TERM -- "-$child" 2>/dev/null || true
            for _ in 1 2 3 4 5; do
              if ! kill -0 "$child" 2>/dev/null; then break; fi
              sleep 1
            done
            kill -KILL -- "-$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
            child=""
          fi
          if [ "$pre_attempted" -eq 1 ]; then
            if ! setsid timeout --signal=TERM --kill-after=5s 60s ${pkgs.bash}/bin/bash -euo pipefail -c ${
              lib.escapeShellArg (if nativePost == null then "true" else nativePost)
            }; then
              status=1
            fi
            if [ "$status" -ne 0 ]; then
              rm -f -- ${lib.escapeShellArg "${stagedDump}.tmp"} || status=1
            fi
          fi
          if [ "$restart_needed" -eq 1 ]; then
            if ! setsid timeout --signal=TERM --kill-after=5s 60s ${serviceController} start vaultwarden.service; then
              status=1
            fi
          fi
          if [ "$status" -eq 0 ] && [ "$finished" -eq 1 ]; then
            if ! cp -- ${marker} "$output/format-version"; then status=1; fi
          fi
          if [ "$status" -ne 0 ]; then
            rm -rf -- "$output/vaultwarden-app" "$output/pg-dump" "$output/format-version"
          fi
          exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        activity=$(timeout --signal=TERM --kill-after=5s 20s ${serviceController} is-active vaultwarden.service) || {
          case "$activity" in inactive|failed) ;; *) exit 1 ;; esac
        }
        case "$activity" in
          active)
            restart_needed=1
            run_step timeout --signal=TERM --kill-after=5s 60s ${serviceController} stop vaultwarden.service
            ;;
          inactive|failed) ;;
          *) exit 1 ;;
        esac

        pre_attempted=1
        run_step timeout --signal=TERM --kill-after=5s 600s ${pkgs.bash}/bin/bash -euo pipefail -c ${lib.escapeShellArg nativePre}
        test -f ${lib.escapeShellArg stagedDump}
        test ! -L ${lib.escapeShellArg stagedDump}
        test -d ${lib.escapeShellArg appDirectory}
        test ! -L ${lib.escapeShellArg appDirectory}
        test -z "$(find ${lib.escapeShellArg appDirectory} \( ! -type f -a ! -type d \) -print -quit)"
        mkdir "$output/vaultwarden-app"
        run_step timeout --signal=TERM --kill-after=5s 600s cp -a --no-preserve=ownership -- ${lib.escapeShellArg "${appDirectory}/."} "$output/vaultwarden-app/"
        run_step timeout --signal=TERM --kill-after=5s 600s chmod -R a+rX "$output/vaultwarden-app"
        run_step timeout --signal=TERM --kill-after=5s 600s cp -- ${lib.escapeShellArg stagedDump} "$output/pg-dump"
        chmod a+r "$output/pg-dump"
        finished=1
      '';
    }
  );
  validate = lib.getExe (
    pkgs.writeShellApplication {
      name = "validate-vaultwarden-recovery";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.findutils
      ];
      text = ''
        test "$#" -eq 1
        input=$1
        case "$input" in /*) ;; *) exit 1 ;; esac
        test -d "$input" && test ! -L "$input"
        if ! test -f "$input/format-version" || test -L "$input/format-version" || ! cmp -s -- "$input/format-version" ${marker}; then
          echo 'Vaultwarden recovery: missing or unsupported format (expected ${formatVersion})' >&2
          exit 1
        fi
        unusual=$(find "$input" \( ! -type f -a ! -type d \) -print -quit) || exit 1
        test -z "$unusual"
        test -f "$input/pg-dump" && test ! -L "$input/pg-dump"
        context=/tmp/apps-vaultwarden-recovery-context
        test ! -e "$context" && test ! -L "$context"
        mkdir -m 700 "$context"
        trap 'rm -rf -- "$context"' EXIT
        printf '%s\n' "$input" > "$context/input-path"
        ${validator} "$input"
      '';
    }
  );
in
{
  contractVersion = 1;
  inherit formatVersion;
  stateRefs = [
    "vaultwarden-app"
    "${database}-db"
  ];
  captureCommand = capture;
  validateCommand = validate;
}
