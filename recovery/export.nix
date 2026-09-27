{
  lib,
  pkgs,
  id,
  unit,
  sourceRevision ? null,
  root ? "/var/lib/clanwright-app-exports/${id}",
}:
let
  validator = import ./validate.nix {
    inherit lib pkgs id;
    validateCommand = unit.validateCommand;
  };
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.findutils
    pkgs.jq
    pkgs.util-linux
  ];
  format = lib.escapeShellArg unit.formatVersion;
  appId = lib.escapeShellArg id;
  exportRoot = lib.escapeShellArg root;
  validatorPath = lib.escapeShellArg (toString validator);
  revision = lib.escapeShellArg (if sourceRevision == null then "" else sourceRevision);
  common = ''
    root=${exportRoot}
    umask 077
    test "$(id -u)" -eq 0
    test -d "$root" && test ! -L "$root"
    test "$(stat -c %u:%a "$root")" = 0:700
    current_target() {
      if test ! -e "$root/current" && test ! -L "$root/current"; then
        return 1
      fi
      test -L "$root/current" || { echo 'invalid export pointer' >&2; exit 1; }
      target=$(readlink -- "$root/current")
      [[ "$target" =~ ^complete-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || {
        echo 'invalid export pointer' >&2; exit 1;
      }
      test -d "$root/$target" && test ! -L "$root/$target" || {
        echo 'missing export target' >&2; exit 1;
      }
      printf '%s\n' "$target"
    }
    lock_publication() {
      exec 9>"$root/publication.lock"
      flock -w 30 "$1" 9 || { echo 'export publication lock timed out' >&2; exit 1; }
    }
  '';
  prepare = pkgs.writeShellApplication {
    name = "apps-export-${id}-prepare";
    inherit runtimeInputs;
    text = common + ''
      lock_publication -x
      if test -e "$root/current" || test -L "$root/current"; then
        keep=$(current_target)
      else
        keep=""
      fi
      for old in "$root"/complete-*; do
        test -e "$old" || test -L "$old" || continue
        test "$old" = "$root/$keep" && continue
        timeout --signal=TERM --kill-after=5s 30s rm -rf -- "$old"
      done
      timeout --signal=TERM --kill-after=5s 30s rm -rf -- "$root/pending"
      rm -f -- "$root/.current-tmp"
      mkdir -m 700 -- "$root/pending"
      capture_id=$(cat /proc/sys/kernel/random/uuid)
      printf '%s\n' "$capture_id" > /run/apps-export-${id}/capture-id
      date -u +%s > /run/apps-export-${id}/capture-start
    '';
  };
  publish = pkgs.writeShellApplication {
    name = "apps-export-${id}-publish";
    inherit runtimeInputs;
    text = common + ''
      id=${appId}
      format=${format}
      validator=${validatorPath}
      revision=${revision}
      pending="$root/pending"
      test -d "$pending" && test ! -L "$pending"
      test -f "$pending/format-version" && test ! -L "$pending/format-version"
      printf '%s\n' "$format" | cmp -s - "$pending/format-version" || {
        echo 'capture returned without matching owner marker' >&2; exit 1;
      }
      capture_id=$(cat /run/apps-export-${id}/capture-id)
      case "$capture_id" in *[!a-f0-9-]*|"") exit 1 ;; esac
      started=$(cat /run/apps-export-${id}/capture-start)
      completed=$(date -u +%s)
      target="complete-$capture_id"
      test ! -e "$root/$target" && test ! -L "$root/$target"
      jq -n --arg id "$id" --arg capture "$capture_id" --argjson start "$started" \
        --argjson complete "$completed" --arg format "$format" \
        --arg validator "$validator" --arg revision "$revision" \
        '{schemaVersion:1,appId:$id,captureId:$capture,captureStartedAt:$start,captureCompletedAt:$complete,formatVersion:$format,validatorStorePath:$validator}
         + (if $revision == "" then {} else {sourceRevision:$revision} end)' \
        > "$pending/export.json"
      lock_publication -x
      if test -e "$root/current" || test -L "$root/current"; then
        old=$(current_target)
      else
        old=""
      fi
      mv -T -- "$pending" "$root/$target"
      ln -s -- "$target" "$root/.current-tmp"
      mv -Tf -- "$root/.current-tmp" "$root/current"
      if test -n "$old"; then
        timeout --signal=TERM --kill-after=5s 30s rm -rf -- "$root/$old" || {
          echo 'export published; previous generation reclamation failed' >&2; exit 1;
        }
      fi
    '';
  };
  cleanup = pkgs.writeShellApplication {
    name = "apps-export-${id}-cleanup";
    inherit runtimeInputs;
    text = common + ''
      timeout --signal=TERM --kill-after=5s 30s rm -rf -- "$root/pending"
      rm -f -- "$root/.current-tmp"
    '';
  };
  reader = pkgs.writeShellApplication {
    name = "prepare-reader";
    inherit runtimeInputs;
    text = common + ''
      id=${appId}
      format=${format}
      test "$#" -eq 3 && test "$1" = --max-age || {
        echo 'usage: prepare-reader --max-age SECONDS ABSOLUTE_EMPTY_DIRECTORY' >&2; exit 1;
      }
      max_age=$2
      case "$max_age" in *[!0-9]*|"") exit 1 ;; esac
      test "$max_age" -gt 0
      output=$3
      case "$output" in /*) ;; *) exit 1 ;; esac
      test -d "$output" && test ! -L "$output"
      test "$(stat -c %u:%a "$output")" = 0:700
      resolved_root=$(realpath -e -- "$root")
      resolved_output=$(realpath -e -- "$output")
      case "$resolved_output" in
        "$resolved_root"|"$resolved_root"/*) echo 'reader directory is inside export state' >&2; exit 1 ;;
      esac
      if ! entries=$(timeout --signal=TERM --kill-after=5s 30s find "$output" -mindepth 1 -print -quit); then
        echo 'reader directory scan failed' >&2; exit 1
      fi
      test -z "$entries"
      lock_publication -s
      target=$(current_target) || { echo 'no published export' >&2; exit 1; }
      source="$root/$target"
      if ! entries=$(timeout --signal=TERM --kill-after=5s 30s find "$source" \
        \( \( ! -type f -a ! -type d \) -o \( -type f -links +1 \) \) -print -quit); then
        echo 'export source scan failed' >&2; exit 1
      fi
      test -z "$entries"
      check_age() {
        metadata=$1
        test -f "$metadata" && test ! -L "$metadata"
        jq -e --arg id "$id" --arg format "$format" \
          --arg capture "''${target#complete-}" \
          '.schemaVersion == 1 and .appId == $id and .formatVersion == $format and .captureId == $capture and (.validatorStorePath | type == "string") and (.captureStartedAt | type == "number") and (.captureCompletedAt | type == "number")' \
          "$metadata" >/dev/null
        started=$(jq -r '.captureStartedAt' "$metadata")
        completed=$(jq -r '.captureCompletedAt' "$metadata")
        case "$started" in *[!0-9]*|"") echo 'invalid export timestamps' >&2; exit 1 ;; esac
        case "$completed" in *[!0-9]*|"") echo 'invalid export timestamps' >&2; exit 1 ;; esac
        now=$(date -u +%s)
        test "$started" -le "$completed" && test "$completed" -le "$now" && test "$((now-started))" -le "$max_age" || {
          echo 'export is future-dated or older than max-age' >&2; exit 1;
        }
      }
      printf '%s\n' "$format" | cmp -s - "$source/format-version"
      check_age "$source/export.json"
      touch "$output/.incomplete"
      timeout --signal=TERM --kill-after=5s 600s cp -a --reflink=auto --no-preserve=links -- "$source/." "$output/"
      check_age "$output/export.json"
      rm -f -- "$output/.incomplete"
    '';
  };
in
assert lib.assertMsg (builtins.elem id [
  "vaultwarden"
  "livesync"
]) "Apps export supports only its two application IDs";
{
  package = pkgs.runCommand "apps-export-${id}" { } ''
    mkdir -p "$out/bin"
    ln -s ${reader}/bin/prepare-reader "$out/bin/prepare-reader"
    ln -s ${validator}/bin/validate "$out/bin/validate"
  '';
  serviceConfig = {
    Type = "oneshot";
    User = "root";
    Group = "root";
    UMask = "0077";
    StateDirectory = "clanwright-app-exports/${id}";
    StateDirectoryMode = "0700";
    RuntimeDirectory = "apps-export-${id}";
    RuntimeDirectoryMode = "0700";
    ExecStartPre = "${prepare}/bin/apps-export-${id}-prepare";
    ExecStart = "${unit.captureCommand} ${root}/pending";
    ExecStartPost = "${publish}/bin/apps-export-${id}-publish";
    ExecStopPost = "${cleanup}/bin/apps-export-${id}-cleanup";
    KillMode = "mixed";
    TimeoutStartSec = "1h";
    TimeoutStopSec = if id == "vaultwarden" then "180s" else "90s";
  };
}
