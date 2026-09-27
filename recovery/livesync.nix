{
  lib,
  pkgs,
  config,
  tools,
  appsPkgs,
  settings,
  serviceController ? "${pkgs.systemd}/bin/systemctl",
  sourceDirectory ? config.services.couchdb.databaseDir,
  nodeName ? "couchdb@127.0.0.1",
  lockPath ? "/run/lock/apps-livesync-recovery.lock",
}:
let
  formatVersion = "livesync-couchdb3-v1";
  marker = pkgs.writeText "livesync-recovery-format" "${formatVersion}\n";
  check = lib.getExe (
    pkgs.writeShellApplication {
      name = "check-livesync-recovery";
      excludeShellChecks = [ "SC2016" ]; # jq variables are intentionally in single-quoted programs.
      runtimeInputs = [
        pkgs.coreutils
        appsPkgs.curl
        appsPkgs.jq
      ];
      text = ''
        : "''${COUCHDB_URL:?missing disposable CouchDB URL}"
        : "''${COUCHDB_USER:?missing disposable CouchDB user}"
        : "''${COUCHDB_PASSWORD:?missing disposable CouchDB password}"
        # The production instance stores the LiveSync data in the obsidian DB.
        curl -fsS --max-time 30 -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "$COUCHDB_URL/_all_dbs" \
          | jq -e 'index("obsidian") != null' >/dev/null
        curl -fsS --max-time 600 -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
          "$COUCHDB_URL/obsidian/_all_docs?include_docs=true&conflicts=true" > /tmp/livesync-docs.json
        : > /tmp/livesync-conflicts.jsonl
        while IFS=$'\t' read -r document revision; do
          curl -fsS --max-time 30 -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
            "$COUCHDB_URL/obsidian/$document?rev=$revision" >> /tmp/livesync-conflicts.jsonl
          printf '\n' >> /tmp/livesync-conflicts.jsonl
        done < <(jq -r '.rows[] | .doc as $doc | ($doc._conflicts // [])[] | [($doc._id | @uri), (. | @uri)] | @tsv' /tmp/livesync-docs.json)
        jq -e --slurpfile conflicts /tmp/livesync-conflicts.jsonl '
          (.rows | map(select(.doc != null) | .doc)) + $conflicts as $docs
          | ($docs | group_by(._id) | map({ key: .[0]._id, value: . }) | from_entries) as $byId
          | all($docs[];
              . as $parent
              | if ($parent.type == "leaf" and $parent._deleted != true)
                then ($parent.data | type == "string")
                elif (($parent.type == "plain" or $parent.type == "newnote")
                    and $parent._deleted != true and $parent.deleted != true)
                then (($parent.children // []) | type == "array")
                  and all($parent.children[];
                    . as $child
                    | (($parent.eden[$child].data | type) == "string")
                      or (($byId[$child] // []) | any(.[];
                          .type == "leaf" and ._deleted != true and (.data | type == "string"))))
                else true end)
        ' /tmp/livesync-docs.json >/dev/null
      '';
    }
  );
  native = tools.mkCouchdbRecovery {
    inherit sourceDirectory nodeName;
    checkCommand = check;
  };
  capture = lib.getExe (
    pkgs.writeShellApplication {
      name = "capture-livesync-recovery";
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
        exec 9>${lib.escapeShellArg lockPath}
        flock -x 9
        child=""
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
          if [ "$restart_needed" -eq 1 ]; then
            if ! setsid timeout --signal=TERM --kill-after=5s 60s ${serviceController} start couchdb.service; then
              status=1
            fi
          fi
          if [ "$status" -eq 0 ] && [ "$finished" -eq 1 ]; then
            if ! cp -- ${marker} "$output/format-version"; then status=1; fi
          fi
          if [ "$status" -ne 0 ]; then
            rm -rf -- "$output/couchdb" "$output/format-version"
          fi
          exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 129' HUP
        trap 'exit 130' INT
        trap 'exit 143' TERM

        activity=$(timeout --signal=TERM --kill-after=5s 20s ${serviceController} is-active couchdb.service) || {
          case "$activity" in inactive|failed) ;; *) exit 1 ;; esac
        }
        case "$activity" in
          active)
            restart_needed=1
            run_step timeout --signal=TERM --kill-after=5s 60s ${serviceController} stop couchdb.service
            ;;
          inactive|failed) ;;
          *) exit 1 ;;
        esac
        mkdir -m 700 "$output/couchdb"
        run_step timeout --signal=TERM --kill-after=5s 600s ${native.captureCommand} "$output/couchdb"
        test -z "$(find "$output/couchdb" \( ! -type f -a ! -type d \) -print -quit)"
        finished=1
      '';
    }
  );
  validate = lib.getExe (
    pkgs.writeShellApplication {
      name = "validate-livesync-recovery";
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
          echo 'LiveSync recovery: missing or unsupported format (expected ${formatVersion})' >&2
          exit 1
        fi
        unusual=$(find "$input" \( ! -type f -a ! -type d \) -print -quit) || exit 1
        test -z "$unusual"
        test -d "$input/couchdb" && test ! -L "$input/couchdb"
        exec ${native.validateCommand} "$input/couchdb"
      '';
    }
  );
in
assert lib.assertMsg (
  toString config.services.couchdb.argsFile == "${config.services.couchdb.package}/etc/vm.args"
) "Apps LiveSync recovery requires the pinned CouchDB default argsFile with node couchdb@127.0.0.1";
{
  contractVersion = 1;
  inherit formatVersion;
  stateRefs = [ "obsidian" ];
  captureCommand = capture;
  validateCommand = validate;
}
