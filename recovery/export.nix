{
  lib,
  pkgs,
  id,
  producer,
  root ? "/var/lib/clanwright-app-exports/${id}",
}:
let
  validator = import ./validate.nix {
    inherit lib pkgs id;
    executable = producer.validate;
  };
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.findutils
    pkgs.jq
    pkgs.util-linux
    pkgs.systemd
  ];
  format = lib.escapeShellArg producer.formatVersion;
  appId = lib.escapeShellArg id;
  exportRoot = lib.escapeShellArg root;
  validatorPath = lib.escapeShellArg (toString validator);
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
  lifecycle = common + ''
    id=${appId}
    format=${format}
    unit=apps-export-${id}.service
    app_unit=${lib.escapeShellArg producer.appUnit}
    record="$root/attempt.json"
    inhibit="$root/inhibit"
    invocation="''${INVOCATION_ID:-}"
    [[ "$invocation" =~ ^[a-f0-9]{32}$ ]] || { echo 'missing native invocation ownership' >&2; exit 1; }
    test "$(uname -s)" = Linux && test "$(cat /proc/1/comm)" = systemd
    test "$(stat -f -c %T /sys/fs/cgroup)" = cgroup2fs
    test "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)"
    test "$(readlink /proc/self/ns/cgroup)" = "$(readlink /proc/1/ns/cgroup)"
    exec 8>"$root/producer.lock"
    flock -n -x 8 || { echo 'export phase already running' >&2; exit 1; }
    manager() {
      local deadline=60s
      if test "$1" = show; then deadline=20s; fi
      timeout --signal=TERM --kill-after=5s "$deadline" env -i ${pkgs.systemd}/bin/systemctl --system --no-pager "$@"
    }
    snapshot() {
      local name=$1 key value
      load_state="" active_state="" job="" control_group="" manager_invocation=""
      local result
      result=$(manager show "$name" -p LoadState -p ActiveState -p Job -p ControlGroup -p InvocationID) || return 1
      while IFS='=' read -r key value; do
        case "$key" in
          LoadState) load_state=$value ;;
          ActiveState) active_state=$value ;;
          Job) job=$value ;;
          ControlGroup) control_group=$value ;;
          InvocationID) manager_invocation=$value ;;
        esac
      done <<< "$result"
      test "$load_state" = loaded || return 1
      case "$control_group" in ""|/system.slice/*) ;; *) return 1 ;; esac
      case "$control_group" in *..*|*//* ) return 1 ;; esac
    }
    app_snapshot() {
      snapshot "$app_unit" && [[ "$job" =~ ^(0)?$ ]]
    }
    owns_native_unit() {
      snapshot "$unit" && test "$manager_invocation" = "$invocation" && test -n "$control_group"
    }
    capture_gone() {
      # The finalizer itself is still in this cgroup. Observe with shell
      # builtins, so cat/find/ps cannot become a spurious writer descendant.
      owns_native_unit || return 1
      local cgroup="/sys/fs/cgroup$control_group" self_group hierarchy controllers pid file
      IFS=: read -r hierarchy controllers self_group < /proc/$$/cgroup || return 1
      test "$hierarchy" = 0 && test -z "$controllers" || return 1
      case "$self_group" in "$control_group"|"$control_group"/*) ;; *) return 1 ;; esac
      test -d "$cgroup" && test ! -L "$cgroup" || return 1
      shopt -s globstar nullglob
      local files=("$cgroup/cgroup.procs" "$cgroup"/**/cgroup.procs)
      for file in "''${files[@]}"; do
        test -r "$file" && test ! -L "$file" || return 1
        while IFS= read -r pid; do
          test "$pid" = "$$" || return 1
        done < "$file"
      done
      shopt -u globstar nullglob
    }
    empty_cgroup() {
      local path=$1 key value empty=0
      test -n "$path" || return 0
      local cgroup="/sys/fs/cgroup$path"
      if test ! -e "$cgroup" && test ! -L "$cgroup"; then return 0; fi
      test -d "$cgroup" && test ! -L "$cgroup" && test -r "$cgroup/cgroup.events" || return 1
      while read -r key value; do
        if test "$key" = populated && test "$value" = 0; then empty=1; fi
      done < "$cgroup/cgroup.events"
      test "$empty" = 1
    }
    app_quiescent() {
      app_snapshot || return 1
      case "$active_state" in inactive|failed) ;; *) return 1 ;; esac
      empty_cgroup "$control_group" && empty_cgroup "$app_cgroup"
    }
    read_record() {
      test -f "$record" && test ! -L "$record" && test "$(stat -c %u:%a "$record")" = 0:600 || return 1
      jq -e --arg id "$id" --arg unit "$unit" --arg app "$app_unit" '
        .schemaVersion == 1 and .appId == $id and .unit == $unit and .appUnit == $app
        and (.invocation | type == "string" and test("^[a-f0-9]{32}$"))
        and (.captureId | type == "string" and test("^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$"))
        and (.previousCurrent | type == "string" and (. == "" or test("^complete-[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$")))
        and (.priorActive | type == "boolean") and (.captureStartedAt | type == "number" and floor == . and . >= 0)
        and (.appCgroup | type == "string" and (. == "" or startswith("/system.slice/")) and (contains("..") | not))
        and (.phase | IN("admitted", "stopping", "prepared", "capture", "restoring", "publishing", "finalized", "reclaiming", "unknown"))
        and ([.stopSubmitted,.stopAcknowledged,.resumeSubmitted,.resumeAcknowledged,.activityRestored,.captureGone] | all(type == "boolean"))
      ' "$record" >/dev/null || return 1
      record_invocation=$(jq -r .invocation "$record") || return 1
      capture_id=$(jq -r .captureId "$record") || return 1
      previous=$(jq -r .previousCurrent "$record") || return 1
      prior_active=$(jq -r .priorActive "$record") || return 1
      app_cgroup=$(jq -r .appCgroup "$record") || return 1
      phase=$(jq -r .phase "$record") || return 1
      pending="$root/pending-$capture_id"
      complete="$root/complete-$capture_id"
    }
    own_record() {
      read_record && test "$record_invocation" = "$invocation" && owns_native_unit
    }
    update_record() {
      local temporary
      temporary=$(mktemp "$root/.attempt.XXXXXXXXXX") || return 1
      jq "$@" "$record" > "$temporary" || return 1
      mv -Tf -- "$temporary" "$record" || return 1
      read_record
    }
    unknown() {
      echo 'export lifecycle unknown; retained attempt, payload and inhibition; operator inspection required' >&2
      update_record '.phase = "unknown"'
      return 1
    }
    validate_current() {
      current=""
      if test -e "$root/current" || test -L "$root/current"; then
        current=$(current_target) || return 1
        local source="$root/$current"
        test "$(stat -c %u:%a "$source")" = 0:700
        test -f "$source/export.json" && test ! -L "$source/export.json"
        test -f "$source/format-version" && test ! -L "$source/format-version"
        printf '%s\n' "$format" | cmp -s - "$source/format-version"
        jq -e --arg id "$id" --arg format "$format" --arg capture "''${current#complete-}" '
          .schemaVersion == 1 and .appId == $id and .captureId == $capture and .formatVersion == $format
          and (.captureStartedAt | type == "number") and (.captureCompletedAt | type == "number")
          and (.validatorStorePath | type == "string")
        ' "$source/export.json" >/dev/null
      fi
    }
    inhibit_owned() {
      test -f "$inhibit" && test ! -L "$inhibit" && test "$(stat -c %u:%a "$inhibit")" = 0:600 || return 1
      test "$(< "$inhibit")" = "$record_invocation $capture_id"
    }
    restore_activity() {
      capture_gone || { unknown; return 1; }
      update_record '.captureGone = true'
      if test "$(jq -r .activityRestored "$record")" = true; then
        test ! -e "$inhibit" && test ! -L "$inhibit" || { unknown; return 1; }
      else
        if test "$(jq -r .resumeSubmitted "$record")" = true; then unknown; return 1; fi
        if test "$(jq -r .stopSubmitted "$record")" = true && test "$(jq -r .stopAcknowledged "$record")" != true; then unknown; return 1; fi
        if test -e "$inhibit" || test -L "$inhibit"; then
          if ! inhibit_owned || ! app_quiescent; then unknown; return 1; fi
          update_record '.phase = "restoring"'
          rm -- "$inhibit"
        elif test "$phase" != admitted && test "$phase" != restoring; then
          unknown; return 1
        fi
        app_snapshot || { unknown; return 1; }
        if test "$prior_active" = true && test "$active_state" != active; then
          case "$active_state" in inactive|failed) ;; *) unknown; return 1 ;; esac
          update_record '.resumeSubmitted = true'
          manager start "$app_unit" || { unknown; return 1; }
          update_record '.resumeAcknowledged = true'
        fi
      fi
      app_snapshot || { unknown; return 1; }
      if test "$prior_active" = true; then
        test "$active_state" = active || { unknown; return 1; }
      else
        app_quiescent || { unknown; return 1; }
      fi
      update_record '.activityRestored = true'
    }
    verify_payload_slots() {
      local path name count=0
      if test -n "$capture_id" && test -d "$pending" && test -d "$complete"; then
        echo 'both pending and complete payload exist for one attempt' >&2; return 1
      fi
      for path in "$root"/pending "$root"/pending-* "$root"/complete-*; do
        test -e "$path" || test -L "$path" || continue
        count=$((count+1))
        test "$count" -le 2 || { echo 'producer payload bound exceeded' >&2; return 1; }
        name="''${path##*/}"
        test -d "$path" && test ! -L "$path" && test "$(stat -c %u:%a "$path")" = 0:700 || return 1
        case "$name" in "$current") ;;
          "pending-$capture_id"|"complete-$capture_id"|"$previous") test -n "$capture_id" || return 1 ;;
          *) echo 'unowned producer payload; operator inspection required' >&2; return 1 ;;
        esac
      done
      for path in "$root"/.current-tmp "$root"/.current-*; do
        test -e "$path" || test -L "$path" || continue
        test -n "$capture_id" && test "$path" = "$root/.current-$capture_id" \
          && test -L "$path" && test "$(readlink -- "$path")" = "complete-$capture_id" || return 1
      done
    }
    remove_unselected() {
      local path=$1 name="''${1##*/}"
      test "$name" != "$current" || { echo 'selected export is never a cleanup target' >&2; return 1; }
      if test -e "$path" || test -L "$path"; then
        test -d "$path" && test ! -L "$path" && test "$(stat -c %u:%a "$path")" = 0:700 || return 1
        timeout --signal=TERM --kill-after=5s 30s rm -rf -- "$path" || return 1
        test ! -e "$path" && test ! -L "$path"
      fi
    }
  '';
  prepare = pkgs.writeShellApplication {
    name = "apps-export-${id}-prepare";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2034"
      "SC2329"
    ];
    text = lifecycle + ''
      owns_native_unit && capture_gone
      lock_publication -x
      validate_current
      capture_id="" previous=""
      if test -e "$record" || test -L "$record"; then
        read_record
        test "$record_invocation" != "$invocation" && test "$phase" = finalized
        test "$(jq -r '.activityRestored and .captureGone' "$record")" = true
        test ! -e "$inhibit" && test ! -L "$inhibit"
        test "$current" = "$previous" || test "$current" = "complete-$capture_id"
        verify_payload_slots
        # A failed/interrupted reclaim is a persistent barrier, never replayed.
        update_record '.phase = "reclaiming"'
        for path in "$pending" "$complete" "$root/$previous"; do
          test "$path" != "$root/" && test "''${path##*/}" != "$current" || continue
          remove_unselected "$path"
        done
        temporary_pointer="$root/.current-$capture_id"
        if test -e "$temporary_pointer" || test -L "$temporary_pointer"; then
          test -L "$temporary_pointer" && test "$(readlink -- "$temporary_pointer")" = "complete-$capture_id"
          rm -- "$temporary_pointer"
        fi
      else
        test ! -e "$inhibit" && test ! -L "$inhibit"
        verify_payload_slots
      fi
      app_snapshot
      case "$active_state" in
        active) prior_active=true ;;
        inactive|failed) prior_active=false; app_cgroup=$control_group; app_quiescent ;;
        *) echo 'app prior activity is unknown' >&2; exit 1 ;;
      esac
      app_cgroup=$control_group
      capture_id=$(cat /proc/sys/kernel/random/uuid)
      started=$(date -u +%s)
      temporary=$(mktemp "$root/.attempt.XXXXXXXXXX")
      jq -n --arg id "$id" --arg unit "$unit" --arg app "$app_unit" \
        --arg invocation "$invocation" --arg capture "$capture_id" --arg previous "$current" \
        --arg cgroup "$app_cgroup" --argjson active "$prior_active" --argjson start "$started" \
        '{schemaVersion:1,appId:$id,unit:$unit,appUnit:$app,invocation:$invocation,captureId:$capture,previousCurrent:$previous,appCgroup:$cgroup,priorActive:$active,captureStartedAt:$start,phase:"admitted",stopSubmitted:false,stopAcknowledged:false,resumeSubmitted:false,resumeAcknowledged:false,activityRestored:false,captureGone:false}' > "$temporary"
      mv -Tf -- "$temporary" "$record"
      own_record
      mkdir -m 700 -- "$pending"
      # ConditionPathExists on the app unit closes its automatic start paths,
      # including an app which was already inactive when admitted.
      (set -C; printf '%s %s\n' "$invocation" "$capture_id" > "$inhibit")
      if test "$prior_active" = true; then
        update_record '.phase = "stopping" | .stopSubmitted = true'
        manager stop "$app_unit" || { unknown; exit 1; }
        update_record '.stopAcknowledged = true'
      fi
      app_quiescent || { unknown; exit 1; }
      update_record '.phase = "prepared"'
    '';
  };
  capture = pkgs.writeShellApplication {
    name = "apps-export-${id}-capture";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2034"
      "SC2329"
    ];
    text = lifecycle + ''
      own_record
      test "$phase" = prepared
      lock_publication -s
      validate_current
      test "$current" = "$previous"
      if ! inhibit_owned || ! app_quiescent || ! capture_gone; then unknown; exit 1; fi
      test -d "$pending" && test ! -L "$pending" && test "$(stat -c %u:%a "$pending")" = 0:700
      update_record '.phase = "capture"'
      exec ${lib.getExe producer.capture} "$pending"
    '';
  };
  publish = pkgs.writeShellApplication {
    name = "apps-export-${id}-publish";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2034"
      "SC2329"
    ];
    text = lifecycle + ''
      own_record
      test "$phase" = capture
      restore_activity
      test -d "$pending" && test ! -L "$pending" && test "$(stat -c %u:%a "$pending")" = 0:700
      # Apply the reader's structural requirements before selecting a new
      # generation. Capture success alone does not exclude links/special files.
      if ! entries=$(timeout --signal=TERM --kill-after=5s 30s find "$pending" \
        \( \( ! -type f -a ! -type d \) -o \( -type f -links +1 \) \) -print -quit); then
        echo 'capture payload scan failed' >&2; exit 1
      fi
      test -z "$entries" || { echo 'capture payload contains links or special files' >&2; exit 1; }
      started=$(jq -r .captureStartedAt "$record")
      completed=$(date -u +%s)
      case "$started" in *[!0-9]*|"") echo 'invalid capture start timestamp' >&2; exit 1 ;; esac
      case "$completed" in *[!0-9]*|"") echo 'invalid capture completion timestamp' >&2; exit 1 ;; esac
      test "$started" -le "$completed" || { echo 'capture clock moved backwards' >&2; exit 1; }
      cp -- ${producer.formatMarker} "$pending/format-version"
      jq -n --arg id "$id" --arg capture "$capture_id" --argjson start "$started" \
        --argjson complete "$completed" --arg format "$format" --arg validator ${validatorPath} \
        '{schemaVersion:1,appId:$id,captureId:$capture,captureStartedAt:$start,captureCompletedAt:$complete,formatVersion:$format,validatorStorePath:$validator}' > "$pending/export.json"
      lock_publication -x
      validate_current
      test "$current" = "$previous"
      verify_payload_slots
      test ! -e "$complete" && test ! -L "$complete"
      update_record '.phase = "finalized"'
      mv -T -- "$pending" "$complete"
      ln -s -- "complete-$capture_id" "$root/.current-$capture_id"
      # Commit is the final useful publication action. Failure/cancellation
      # after this rename never rolls selection back or deletes the payload.
      mv -Tf -- "$root/.current-$capture_id" "$root/current"
    '';
  };
  cleanup = pkgs.writeShellApplication {
    name = "apps-export-${id}-finalize";
    inherit runtimeInputs;
    excludeShellChecks = [
      "SC2016"
      "SC2034"
      "SC2329"
    ];
    text = lifecycle + ''
      if test ! -e "$record" && test ! -L "$record"; then exit 0; fi
      # Rejected admission has no authority over an earlier attempt.
      own_record
      case "$phase" in unknown|reclaiming) echo 'retained unresolved export attempt' >&2; exit 1 ;; esac
      lock_publication -x
      validate_current
      verify_payload_slots
      if test "$current" = "complete-$capture_id"; then
        test "$phase" = finalized && test "$(jq -r '.activityRestored and .captureGone' "$record")" = true
        capture_gone || { unknown; exit 1; }
        # Normal successful deactivation and late cancellation preserve current.
        exit 0
      fi
      test "$current" = "$previous"
      restore_activity
      # Incomplete or unpublished owned generations are safe only after the
      # native writer proof and verified restoration, under the reader lock.
      update_record '.phase = "reclaiming"'
      remove_unselected "$pending"
      remove_unselected "$complete"
      temporary_pointer="$root/.current-$capture_id"
      if test -e "$temporary_pointer" || test -L "$temporary_pointer"; then
        test -L "$temporary_pointer" && test "$(readlink -- "$temporary_pointer")" = "complete-$capture_id"
        rm -- "$temporary_pointer"
      fi
      update_record '.phase = "finalized"'
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
  appUnitCondition = "!${root}/inhibit";
  serviceConfig = {
    Type = "oneshot";
    User = "root";
    Group = "root";
    UMask = "0077";
    StateDirectory = "clanwright-app-exports/${id}";
    StateDirectoryMode = "0700";
    ExecStartPre = "${prepare}/bin/apps-export-${id}-prepare";
    ExecStart = "${capture}/bin/apps-export-${id}-capture";
    ExecStartPost = "${publish}/bin/apps-export-${id}-publish";
    ExecStopPost = "${cleanup}/bin/apps-export-${id}-finalize";
    KillMode = "control-group";
    SendSIGKILL = true;
    Restart = "no";
    Delegate = false;
    RemainAfterExit = false;
    TimeoutStartSec = "1h";
    # Owner/cgroup/app observations (25s each), native resume (65s), reader
    # lock (30s) and two possible reclaims (35s each) fit within six minutes.
    # The native deadline still cannot prove teardown; unfinished records bar
    # the next attempt rather than replaying a stop or resume request.
    TimeoutStopSec = "6min";
  };
}
