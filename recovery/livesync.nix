{
  lib,
  pkgs,
  config,
  tools,
  erlang,
  sourceDirectory ? config.services.couchdb.databaseDir,
  nodeName ? "couchdb@127.0.0.1",
}:
let
  formatVersion = "livesync-couchdb3-v1";
  marker = pkgs.writeText "livesync-recovery-format" "${formatVersion}\n";
  check = pkgs.writeShellApplication {
    name = "check-livesync-recovery";
    excludeShellChecks = [ "SC2016" ]; # jq variables are intentionally in single-quoted programs.
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      : "''${COUCHDB_URL:?missing disposable CouchDB URL}"
      : "''${COUCHDB_USER:?missing disposable CouchDB user}"
      : "''${COUCHDB_PASSWORD:?missing disposable CouchDB password}"
      # The production instance stores the LiveSync data in the obsidian DB.
      curl -fsS --max-time 30 -u "$COUCHDB_USER:$COUCHDB_PASSWORD" "$COUCHDB_URL/_all_dbs" \
        | jq -e 'index("obsidian") != null' >/dev/null
      # Only semantic metadata reaches the global graph check. Keep payloads
      # bounded to one page (or one conflict revision) while preserving types.
      metadata='
        def compact:
          {_id, type, _deleted, deleted, children, data,
           eden: (if (.eden | type) == "object" then
             (.eden | with_entries(.value |=
               if type == "object" then
                 {data: (.data | if type == "string" then "" else . end)}
               else . end))
             else .eden end)}
          | .data |= if type == "string" then "" else . end;
      '
      : > /tmp/livesync-docs.jsonl
      cursor=""
      while :; do
        page_args=()
        if [ -n "$cursor" ]; then
          page_args=(--data-urlencode "startkey=$cursor" --data-urlencode 'skip=1')
        fi
        curl -fsS --max-time 30 -u "$COUCHDB_USER:$COUCHDB_PASSWORD" --get \
          --data-urlencode 'include_docs=true' --data-urlencode 'conflicts=true' \
          --data-urlencode 'limit=32' "''${page_args[@]}" \
          "$COUCHDB_URL/obsidian/_all_docs" > /tmp/livesync-page.json
        jq -e '.rows | type == "array" and length <= 32
          and all(.[]; (.id | type) == "string" and (.doc | type) == "object"
            and .id == .doc._id)' /tmp/livesync-page.json >/dev/null
        count=$(jq '.rows | length' /tmp/livesync-page.json)
        if [ "$count" -eq 0 ]; then break; fi
        next_cursor=$(jq -c '.rows[-1].id' /tmp/livesync-page.json)
        test "$next_cursor" != "$cursor"
        jq -c "$metadata .rows[].doc | compact" /tmp/livesync-page.json >> /tmp/livesync-docs.jsonl
        jq -r '.rows[] | .doc as $doc | ($doc._conflicts // [])[] | [($doc._id | @uri), (. | @uri)] | @tsv' \
          /tmp/livesync-page.json > /tmp/livesync-conflicts.tsv
        while IFS=$'\t' read -r document revision; do
          curl -fsS --max-time 30 -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
            "$COUCHDB_URL/obsidian/$document?rev=$revision" \
            | jq -ce "$metadata compact" >> /tmp/livesync-docs.jsonl
        done < /tmp/livesync-conflicts.tsv
        cursor=$next_cursor
        if [ "$count" -lt 32 ]; then break; fi
      done
      jq -e -s '
        . as $docs
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
      ' /tmp/livesync-docs.jsonl >/dev/null
    '';
  };
  native = tools.mkCouchdbRecovery {
    inherit sourceDirectory nodeName;
    couchdb = config.services.couchdb.package;
    inherit check erlang;
  };
  capture = pkgs.writeShellApplication {
    name = "capture-livesync-recovery";
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
      # The native exporter unit has already inhibited and quiesced CouchDB.
      mkdir -m 700 "$output/couchdb"
      timeout --signal=TERM --kill-after=5s 600s ${lib.getExe native.capture} "$output/couchdb"
      test -z "$(find "$output/couchdb" \( ! -type f -a ! -type d \) -print -quit)"
    '';
  };
  validate = pkgs.writeShellApplication {
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
      exec ${lib.getExe native.validate} "$input/couchdb"
    '';
  };
in
assert lib.assertMsg (
  toString config.services.couchdb.argsFile == "${config.services.couchdb.package}/etc/vm.args"
) "Apps LiveSync recovery requires the pinned CouchDB default argsFile with node couchdb@127.0.0.1";
{
  inherit formatVersion capture validate;
  appUnit = "couchdb.service";
  formatMarker = marker;
}
