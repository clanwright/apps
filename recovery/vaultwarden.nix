{
  lib,
  pkgs,
  config,
  tools,
  appDirectory ? builtins.head config.clan.core.state.vaultwarden-app.folders,
  databaseDump ?
    let
      actor = pkgs.writeShellApplication {
        name = "vaultwarden-database-export-actor";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          # An absent app process does not prove that its disconnected SQL
          # backend has stopped. Observe ALL app-role backends and prepared
          # transactions once, in a fresh admin connection; never poll or kill.
          idle=$(timeout --signal=TERM --kill-after=5s 20s ${config.services.postgresql.package}/bin/psql -X --no-password -A -t \
            --set ON_ERROR_STOP=1 --host=/run/postgresql \
            --port=${toString config.services.postgresql.settings.port} --username=postgres --dbname=postgres \
            --set ${lib.escapeShellArg "app_db=vaultwarden"} \
            --set ${lib.escapeShellArg "app_role=vaultwarden"} < ${./vaultwarden-quiescence.sql}
          )
          test "$idle" = t || { echo 'Vaultwarden database still has app backends or prepared transactions' >&2; exit 1; }
          # Only the archive reaches the root-opened inherited stdout FD.
          exec ${config.services.postgresql.package}/bin/pg_dump --format=custom --no-password \
            --host=/run/postgresql --port=${toString config.services.postgresql.settings.port} \
            --username=postgres --dbname=${lib.escapeShellArg "vaultwarden"}
        '';
      };
    in
    pkgs.writeShellApplication {
      name = "dump-vaultwarden-database";
      text = ''
        exec ${pkgs.util-linux}/bin/runuser -u postgres -- \
          ${pkgs.coreutils}/bin/env -i PGPASSFILE=/dev/null ${lib.getExe actor}
      '';
    },
}:
let
  database = "vaultwarden";
  formatVersion = "vaultwarden-pg18-files-v1";
  marker = pkgs.writeText "vaultwarden-recovery-format" "${formatVersion}\n";
  postgres = config.services.postgresql.package;
  check = pkgs.writeShellApplication {
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
  };
  validator = tools.mkPostgresqlValidator {
    dumpRelativePath = "pg-dump";
    postgresql = postgres;
    inherit database check;
  };
  capture = pkgs.writeShellApplication {
    name = "capture-vaultwarden-recovery";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      test "$#" -eq 1
      output=$1
      case "$output" in /*) ;; *) exit 1 ;; esac
      test -d "$output" && test ! -L "$output"
      test "$(stat -c %u "$output")" = "$(id -u)"
      test "$(stat -c %a "$output")" = 700
      test -z "$(find "$output" -mindepth 1 -print -quit)"

      # Native unit hooks own admission, quiescence, teardown and resumption.
      # Every capture operation stays in the foreground of ExecStart.
      # The parent opens the private output before the native postgres actor
      # writes its archive through the inherited stdout descriptor.
      timeout --signal=TERM --kill-after=5s 600s ${lib.getExe databaseDump} > "$output/pg-dump"
      test -d ${lib.escapeShellArg appDirectory}
      test ! -L ${lib.escapeShellArg appDirectory}
      test -z "$(find ${lib.escapeShellArg appDirectory} \( ! -type f -a ! -type d \) -print -quit)"
      mkdir "$output/vaultwarden-app"
      timeout --signal=TERM --kill-after=5s 600s cp -a --no-preserve=ownership,links -- ${lib.escapeShellArg "${appDirectory}/."} "$output/vaultwarden-app/"
      timeout --signal=TERM --kill-after=5s 600s chmod -R a+rX "$output/vaultwarden-app"
      chmod a+r "$output/pg-dump"
    '';
  };
  validate = pkgs.writeShellApplication {
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
      ${lib.getExe validator} "$input"
    '';
  };
in
{
  inherit formatVersion capture validate;
  appUnit = "vaultwarden.service";
  formatMarker = marker;
}
