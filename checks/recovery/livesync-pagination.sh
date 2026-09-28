#!/usr/bin/env bash
# Fast callback regression; no CouchDB process, restored data, or VM required.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
artifact=${1:-"$root/state/issue-5-followup/apps-pagination"}
mkdir -p "$artifact"
artifact=$(cd "$artifact" && pwd)
work=$(mktemp -d "$artifact/fixture.XXXXXX")

# Exercise the actual callback rather than a duplicate implementation.
awk '/      text = '\'''\''/ { if (!started) { started = 1; next } }
  started && /      '\'''\'';/ { exit }
  started { print }' "$root/recovery/livesync.nix" \
  | sed "s|/tmp/livesync-|$work/livesync-|g; s|''\${|\${|g" > "$work/callback.sh"
test -s "$work/callback.sh"
bash -n "$work/callback.sh"

export COUCHDB_URL=http://fixture.invalid COUCHDB_USER=fixture COUCHDB_PASSWORD=fixture
export work
jq -n '
  "z \"\\\n&?leaf" as $leaf
  | [range(0; 63) | "doc-" + (tostring | if length < 2 then "0" + . else . end)
      | {id: ., doc: {_id: ., type: "other", data: ("x" * 20000)}}]
    + [{id: $leaf, doc: {_id: $leaf, type: "leaf", data: ("y" * 20000)}}]
    + [{id: "zz-other", doc: {_id: "zz-other", type: "other"}}]
  | .[0].doc = {_id: .[0].id, type: "plain", children: [$leaf], _conflicts: ["2-fixture"]}
' > "$work/original.json"
printf '%s\n' '{"_id":"doc-00","type":"newnote","children":[],"data":"conflict payload"}' > "$work/original-conflict.json"

curl() {
  local url="" start='null' skip=0 limit=0 timeout=0 argument
  while [ "$#" -gt 0 ]; do
    argument=$1
    shift
    case "$argument" in
      --max-time) timeout=$1; shift ;;
      -u) shift ;;
      --data-urlencode)
        case "$1" in
          startkey=*) start=${1#startkey=} ;;
          skip=*) skip=${1#skip=} ;;
          limit=*) limit=${1#limit=} ;;
        esac
        shift ;;
      http://*) url=$argument ;;
    esac
  done
  test "$timeout" -eq 30
  case "$url" in
    */_all_dbs) printf '%s\n' '["obsidian"]' ;;
    */_all_docs)
      test "$limit" -eq 32
      if [ "$start" != null ]; then test "$skip" -eq 1; fi
      case "${response_mode:-valid}" in
        truncated) printf '%s' '{"rows":['; return ;;
        http-error) return 22 ;;
      esac
      printf '%s\n' "$start" >> "$work/cursors.jsonl"
      jq --argjson start "$start" --argjson skip "$skip" \
        '{rows: (if $start == null then . else map(select(.id >= $start)) | .[$skip:] end | .[:32])}' "$work/documents.json" ;;
    */doc-00?rev=2-fixture) cat "$work/conflict.json" ;;
    *) return 1 ;;
  esac
}
export -f curl

run_case() {
  local name=$1 expected=$2 actual=0
  : > "$work/cursors.jsonl"
  bash -euo pipefail "$work/callback.sh" > "$artifact/$name.log" 2>&1 || actual=$?
  if [ "$expected" = pass ]; then
    test "$actual" -eq 0
  else
    test "$actual" -ne 0
  fi
  printf '%s: expected %s, exit %s\n' "$name" "$expected" "$actual"
}
cp "$work/original.json" "$work/documents.json"
cp "$work/original-conflict.json" "$work/conflict.json"
run_case paginated-cross-page-child pass
test "$(wc -l < "$work/cursors.jsonl")" -eq 3
jq -e -s '.[2] == "z \"\\\n&?leaf"' "$work/cursors.jsonl" >/dev/null
jq -e -s 'length == 66 and all(.[]; .data == null or .data == "")' "$work/livesync-docs.jsonl" >/dev/null
test "$(wc -c < "$work/livesync-docs.jsonl")" -lt 20000

jq '.[-2].doc.data = 123' "$work/original.json" > "$work/documents.json"
run_case non-string-leaf fail
jq '.[-2].doc._deleted = true' "$work/documents.json" > "$work/deleted.json"
cp "$work/deleted.json" "$work/documents.json"
run_case deleted-leaf-does-not-satisfy-child fail
jq '.[0].doc.eden[.[-2].id].data = "inline payload"' "$work/deleted.json" > "$work/documents.json"
run_case inline-eden-string pass
jq '.[0].doc.eden[.[-2].id].data = 123' "$work/deleted.json" > "$work/documents.json"
run_case inline-eden-non-string fail
cp "$work/original.json" "$work/documents.json"
printf '%s\n' '{"_id":"doc-00","type":"newnote","children":["missing"]}' > "$work/conflict.json"
run_case conflict-missing-child fail
cp "$work/original-conflict.json" "$work/conflict.json"
jq '.[0].doc.children = "invalid"' "$work/original.json" > "$work/documents.json"
run_case malformed-children fail
cp "$work/original.json" "$work/documents.json"
export response_mode=truncated
run_case truncated-page fail
export response_mode=http-error
run_case page-http-error fail
unset response_mode
printf 'PASS: callback pagination, payload reduction, and semantic failures\n'
