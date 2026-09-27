#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
expect_failure() {
  local label=$1
  shift
  if "$@"; then fail "$label unexpectedly succeeded"; fi
  pass "$label rejected"
}

root=$fixtureRoot
test -d "$root" || fail 'fixture root missing'
mkdir -p "$root/stage" "$root/vaultwarden/attachments" "$root/pg" "$root/socket"
chmod 700 "$root" "$root/pg" "$root/socket"
printf '%s\n' active > "$root/vaultwarden.state"
printf '%s\n' active > "$root/couchdb.state"
: > "$root/service-events"

cleanup() {
  local status=$?
  trap - EXIT
  if test -f "$root/pg/postmaster.pid"; then pg_ctl -D "$root/pg" -m immediate -w stop || true; fi
  if test -f "$root/couchdb.pid"; then kill "$(cat "$root/couchdb.pid")" 2>/dev/null || true; fi
  if test "$status" -ne 0; then
    printf '\nService events:\n' >&2
    cat "$root/service-events" >&2 || true
    for log in "$out"/*.log "$root/couch.log"; do
      test "$log" != "$out/check.log" || continue
      if test -f "$log"; then
        printf '\n%s:\n' "$log" >&2
        cat "$log" >&2 || true
      fi
    done
  fi
  rm -rf -- "$root"
  exit "$status"
}
trap cleanup EXIT

initdb -D "$root/pg" --no-instructions --auth=trust > "$out/initdb.log" 2>&1
pg_ctl -D "$root/pg" -o "-c unix_socket_directories=$root/socket -c listen_addresses=''" -w start > "$out/pg-start.log" 2>&1
export PGHOST="$root/socket" PGUSER="$(id -un)" PGDATABASE=vaultwarden
createdb vaultwarden
psql -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE users (uuid text PRIMARY KEY);
CREATE TABLE organizations (uuid text PRIMARY KEY);
CREATE TABLE ciphers (uuid text PRIMARY KEY, user_uuid text, organization_uuid text);
CREATE TABLE attachments (id text PRIMARY KEY, cipher_uuid text NOT NULL, file_name text, file_size bigint, akey text);
INSERT INTO users VALUES ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
INSERT INTO ciphers VALUES ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', NULL);
INSERT INTO attachments VALUES ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'encrypted-name', 19, NULL);
SQL
mkdir -p "$root/vaultwarden/attachments/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
printf 'fixture attachment\n' > "$root/vaultwarden/attachments/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/cccccccc-cccc-cccc-cccc-cccccccccccc"
test "$(stat -c %s "$root/vaultwarden/attachments/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/cccccccc-cccc-cccc-cccc-cccccccccccc")" = 19
pg_dump -Fc -f "$root/source.pg-dump" vaultwarden
pg_ctl -D "$root/pg" -m immediate -w stop > "$out/pg-stop.log" 2>&1
pass 'PostgreSQL 18 fixture seeded with linked attachment'

mkdir -m 700 "$root/vw-valid"
"$vwCapture" "$root/vw-valid"
test "$(cat "$root/vaultwarden.state")" = active || fail 'Vaultwarden did not resume'
test ! -e "$root/stage/pg-dump" || fail 'native staging remained after capture'
pass 'Vaultwarden public capture command completed and resumed'

# Validation runs with the same namespace restrictions as the published
# Reliability contract: only store executables, restored input and private tmp.
validate_sandbox() {
  local command=$1 input=$2 mount="${3:-/input}"
  export RECOVERY_HOST_SENTINEL='fixture-not-for-sandbox'
  bwrap --unshare-all --die-with-parent --clearenv \
    --ro-bind /nix/store /nix/store \
    --ro-bind "$input" "$mount" \
    --tmpfs /tmp --proc /proc --dev /dev \
    --dir /bin --symlink "$nixShell" /bin/sh \
    --setenv HOME /tmp --setenv TMPDIR /tmp \
    --setenv PATH "$sandboxPath" \
    --chdir /tmp \
    /bin/sh -c '
      set -eu
      test -z "${RECOVERY_HOST_SENTINEL-}"
      test ! -e /etc/passwd
      test ! -e /run/credentials
      test ! -e "$2"
      test ! -w "$3"
      ip -o addr show dev lo | grep -q '127.0.0.1/'
      test "$(ip -o link show | wc -l)" -eq 1
      exec "$1" "$3"
    ' sandbox "$command" "$root" "$mount"
}

validate_sandbox "$vwValidate" "$root/vw-valid"
pass 'Vaultwarden disposable PostgreSQL import and semantic validation'
validate_sandbox "$vwValidate" "$root/vw-valid" /restored
pass 'Vaultwarden arbitrary restored directory accepted'

cp -a "$root/vw-valid" "$root/vw-unsupported"
rm "$root/vw-unsupported/format-version"
printf '%s\n' unsupported > "$root/vw-unsupported/format-version"
expect_failure 'Vaultwarden unsupported format' validate_sandbox "$vwValidate" "$root/vw-unsupported"

cp -a "$root/vw-valid" "$root/vw-corrupt-dump"
printf '%s\n' corrupt > "$root/vw-corrupt-dump/pg-dump"
expect_failure 'Vaultwarden malformed PostgreSQL archive' validate_sandbox "$vwValidate" "$root/vw-corrupt-dump"

cp -a "$root/vw-valid" "$root/vw-missing-attachment"
rm -f "$root/vw-missing-attachment/vaultwarden-app/attachments/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/cccccccc-cccc-cccc-cccc-cccccccccccc"
expect_failure 'Vaultwarden missing attachment' validate_sandbox "$vwValidate" "$root/vw-missing-attachment"

printf '%s\n' inactive > "$root/vaultwarden.state"
mkdir -m 700 "$root/vw-stopped"
"$vwCapture" "$root/vw-stopped"
test "$(cat "$root/vaultwarden.state")" = inactive || fail 'initially stopped Vaultwarden was started'
pass 'Vaultwarden initially stopped state preserved'

touch "$root/fail-native-pre"
mkdir -m 700 "$root/vw-stopped-failure"
expect_failure 'Vaultwarden initially stopped preparation failure' "$vwCapture" "$root/vw-stopped-failure"
test "$(cat "$root/vaultwarden.state")" = inactive || fail 'stopped Vaultwarden failure started service'
rm "$root/fail-native-pre"

printf '%s\n' active > "$root/vaultwarden.state"
touch "$root/fail-native-pre"
mkdir -m 700 "$root/vw-pre-failure"
expect_failure 'Vaultwarden preparation failure' "$vwCapture" "$root/vw-pre-failure"
test "$(cat "$root/vaultwarden.state")" = active || fail 'preparation failure left Vaultwarden stopped'
rm "$root/fail-native-pre"

touch "$root/fail-native-post"
mkdir -m 700 "$root/vw-post-failure"
expect_failure 'Vaultwarden cleanup failure' "$vwCapture" "$root/vw-post-failure"
test "$(cat "$root/vaultwarden.state")" = active || fail 'cleanup failure left Vaultwarden stopped'
rm "$root/fail-native-post"

mv "$root/vaultwarden" "$root/vaultwarden-hidden"
mkdir -m 700 "$root/vw-copy-failure"
expect_failure 'Vaultwarden copy failure after preparation' "$vwCapture" "$root/vw-copy-failure"
test "$(cat "$root/vaultwarden.state")" = active || fail 'copy failure left Vaultwarden stopped'
test ! -e "$root/vw-copy-failure/format-version" || fail 'copy failure published format marker'
mv "$root/vaultwarden-hidden" "$root/vaultwarden"

touch "$root/fail-vaultwarden-stop"
mkdir -m 700 "$root/vw-stop-failure"
expect_failure 'Vaultwarden stop failure' "$vwCapture" "$root/vw-stop-failure"
test "$(cat "$root/vaultwarden.state")" = active || fail 'stop failure changed Vaultwarden state'
rm "$root/fail-vaultwarden-stop"

touch "$root/fail-vaultwarden-start"
mkdir -m 700 "$root/vw-start-failure"
expect_failure 'Vaultwarden restart failure' "$vwCapture" "$root/vw-start-failure"
test ! -e "$root/vw-start-failure/format-version" || fail 'restart failure published format marker'
rm "$root/fail-vaultwarden-start"
printf '%s\n' active > "$root/vaultwarden.state"

touch "$root/block-vaultwarden-stop"
mkdir -m 700 "$root/vw-terminated"
setsid "$vwCapture" "$root/vw-terminated" > "$out/vw-termination.log" 2>&1 &
capture_pid=$!
for attempt in $(seq 1 100); do
  if test -s "$root/blocked-vaultwarden-pid"; then break; fi
  sleep 0.05
done
test -s "$root/blocked-vaultwarden-pid" || fail 'termination fixture did not block'
blocked_pid=$(cat "$root/blocked-vaultwarden-pid")
kill -TERM -- "-$capture_pid"
if wait "$capture_pid"; then fail 'terminated capture succeeded'; fi
kill -0 "$blocked_pid" 2>/dev/null && fail 'capture left blocked service-controller process running'
test "$(cat "$root/vaultwarden.state")" = active || fail 'terminated capture left Vaultwarden stopped'
test ! -e "$root/vw-terminated/format-version" || fail 'terminated capture published format marker'
rm "$root/block-vaultwarden-stop"
pass 'Vaultwarden catchable termination cleaned child group and resumed'

touch "$root/block-native-pre"
mkdir -m 700 "$root/vw-terminated-pre"
setsid "$vwCapture" "$root/vw-terminated-pre" > "$out/vw-pre-termination.log" 2>&1 &
capture_pid=$!
for attempt in $(seq 1 100); do
  if test -s "$root/blocked-native-pre-pid"; then break; fi
  sleep 0.05
done
test -s "$root/blocked-native-pre-pid" || fail 'native preparation did not block'
blocked_pid=$(cat "$root/blocked-native-pre-pid")
kill -TERM -- "-$capture_pid"
if wait "$capture_pid"; then fail 'terminated preparation succeeded'; fi
kill -0 "$blocked_pid" 2>/dev/null && fail 'native preparation child survived TERM'
test "$(cat "$root/vaultwarden.state")" = active || fail 'terminated preparation left Vaultwarden stopped'
test ! -e "$root/vw-terminated-pre/format-version" || fail 'terminated preparation published format marker'
test ! -e "$root/stage/pg-dump" || fail 'partial native staging remained after TERM'
rm "$root/block-native-pre"
pass 'Vaultwarden TERM during partial native preparation unwound staging'

touch "$root/block-vaultwarden-stop"
rm "$root/blocked-vaultwarden-pid"
mkdir -m 700 "$root/vw-lock-holder" "$root/vw-concurrent"
setsid "$vwCapture" "$root/vw-lock-holder" > "$out/vw-lock-holder.log" 2>&1 &
first_pid=$!
for attempt in $(seq 1 100); do
  if test -s "$root/blocked-vaultwarden-pid"; then break; fi
  sleep 0.05
done
test -s "$root/blocked-vaultwarden-pid" || fail 'Vaultwarden lock holder did not block'
active_before=$(grep -c '^is-active vaultwarden$' "$root/service-events")
"$vwCapture" "$root/vw-concurrent" > "$out/vw-concurrent.log" 2>&1 &
second_pid=$!
sleep 0.2
kill -0 "$second_pid" || fail 'waiting Vaultwarden capture exited early'
test "$(grep -c '^is-active vaultwarden$' "$root/service-events")" = "$active_before" || fail 'concurrent Vaultwarden capture bypassed lock'
test ! -e "$root/vw-concurrent/format-version" || fail 'concurrent Vaultwarden capture published before lock release'
rm "$root/block-vaultwarden-stop"
kill -TERM -- "-$first_pid"
if wait "$first_pid"; then fail 'terminated Vaultwarden lock holder succeeded'; fi
wait "$second_pid" || fail 'waiting Vaultwarden capture failed after lock release'
test -f "$root/vw-concurrent/format-version" || fail 'waiting Vaultwarden capture did not publish'
test ! -e "$root/stage/pg-dump" || fail 'waiting Vaultwarden capture left staging'
test "$(cat "$root/vaultwarden.state")" = active || fail 'waiting Vaultwarden capture left service stopped'
pass 'Vaultwarden capture lock serialized overlap'

# LiveSync fixture and failure cases follow below.
mkdir -p "$root/couchdb" "$root/couch-home"
cat > "$root/couch.ini" <<EOF
[couchdb]
database_dir = $root/couchdb
view_index_dir = $root/couchdb
single_node = true

[admins]
fixture = fixture-password

[chttpd]
bind_address = 127.0.0.1
port = 15984

[log]
file = $root/couch.log
level = warning
EOF
cat > "$root/vm.args" <<'EOF'
-name couchdb@127.0.0.1
-setcookie disposablefixturecookie
-kernel inet_dist_use_interface {127,0,0,1}
+Bd -noinput
EOF
cat > "$root/couch.config" <<EOF
[{public_key, [{cacerts_path, "$couchCaFile"}]}].
EOF
export COUCHDB_SYSCONFIG_FILE="$root/couch.config"
export COUCHDB_INI_FILES="$couchDefaultIni $root/couch.ini"
export COUCHDB_ARGS_FILE="$root/vm.args"
export HOME="$root/couch-home"
url=http://127.0.0.1:15984
start_couch() {
  "$couchExe" >> "$out/couch.stdout.log" 2>> "$out/couch.stderr.log" &
  echo "$!" > "$root/couchdb.pid"
  for attempt in $(seq 1 120); do
    if curl --noproxy '*' -fsS --max-time 2 -u fixture:fixture-password "$url/" > /dev/null 2>&1; then break; fi
    sleep 0.25
  done
  curl --noproxy '*' -fsS --max-time 5 -u fixture:fixture-password "$url/" > "$out/couch-version.json" || fail 'disposable CouchDB failed to start'
}
stop_couch() {
  kill "$(cat "$root/couchdb.pid")"
  wait "$(cat "$root/couchdb.pid")" || true
  rm "$root/couchdb.pid"
}
start_couch
curl --noproxy '*' -fsS --max-time 5 -u fixture:fixture-password -X PUT "$url/obsidian" > "$out/couch-create.json"
curl --noproxy '*' -fsS --max-time 5 -u fixture:fixture-password \
  -H 'Content-Type: application/json' -X POST "$url/obsidian/_bulk_docs" \
  --data-binary '{"docs":[{"_id":"f:fixture-note","type":"plain","path":"note.md","children":["h:fixture-chunk"],"eden":{},"size":7,"ctime":1,"mtime":1},{"_id":"h:fixture-chunk","type":"leaf","data":"content"}]}' \
  > "$out/couch-seed.json"
jq -e 'all(.[]; .ok == true)' "$out/couch-seed.json" > /dev/null
stop_couch
pass 'CouchDB 3.5.2 fixture seeded with linked LiveSync chunk'

mkdir -m 700 "$root/ls-valid"
"$lsCapture" "$root/ls-valid"
test "$(cat "$root/couchdb.state")" = active || fail 'LiveSync did not resume'
validate_sandbox "$lsValidate" "$root/ls-valid"
pass 'LiveSync public capture and disposable CouchDB validation'

start_couch
curl --noproxy '*' -fsS --max-time 5 -u fixture:fixture-password \
  -H 'Content-Type: application/json' -X PUT "$url/obsidian/f:broken-note" \
  --data-binary '{"type":"plain","path":"broken.md","children":["h:missing-chunk"],"eden":{}}' \
  > "$out/couch-broken.json"
stop_couch
mkdir -m 700 "$root/ls-missing-child"
"$lsCapture" "$root/ls-missing-child"
expect_failure 'LiveSync missing active chunk' validate_sandbox "$lsValidate" "$root/ls-missing-child"

cp -a "$root/ls-valid" "$root/ls-unsupported"
rm "$root/ls-unsupported/format-version"
printf '%s\n' unsupported > "$root/ls-unsupported/format-version"
expect_failure 'LiveSync unsupported format' validate_sandbox "$lsValidate" "$root/ls-unsupported"

printf '%s\n' inactive > "$root/couchdb.state"
mkdir -m 700 "$root/ls-stopped"
"$lsCapture" "$root/ls-stopped"
test "$(cat "$root/couchdb.state")" = inactive || fail 'initially stopped CouchDB was started'
pass 'LiveSync initially stopped state preserved'

printf '%s\n' active > "$root/couchdb.state"
touch "$root/fail-couchdb-stop"
mkdir -m 700 "$root/ls-stop-failure"
expect_failure 'LiveSync stop failure' "$lsCapture" "$root/ls-stop-failure"
test "$(cat "$root/couchdb.state")" = active || fail 'stop failure changed CouchDB state'
rm "$root/fail-couchdb-stop"

touch "$root/fail-couchdb-start"
mkdir -m 700 "$root/ls-start-failure"
expect_failure 'LiveSync restart failure' "$lsCapture" "$root/ls-start-failure"
test ! -e "$root/ls-start-failure/format-version" || fail 'restart failure published format marker'
rm "$root/fail-couchdb-start"
printf '%s\n' active > "$root/couchdb.state"

touch "$root/block-couchdb-stop"
mkdir -m 700 "$root/ls-terminated" "$root/ls-concurrent"
setsid "$lsCapture" "$root/ls-terminated" > "$out/ls-termination.log" 2>&1 &
first_pid=$!
for attempt in $(seq 1 100); do
  if test -s "$root/blocked-couchdb-pid"; then break; fi
  sleep 0.05
done
test -s "$root/blocked-couchdb-pid" || fail 'LiveSync stop did not block'
blocked_pid=$(cat "$root/blocked-couchdb-pid")
active_before=$(grep -c '^is-active couchdb$' "$root/service-events")
"$lsCapture" "$root/ls-concurrent" > "$out/ls-concurrent.log" 2>&1 &
second_pid=$!
sleep 0.2
test "$(grep -c '^is-active couchdb$' "$root/service-events")" = "$active_before" || fail 'concurrent LiveSync capture bypassed lock'
test ! -e "$root/ls-concurrent/format-version" || fail 'concurrent capture published before lock release'
rm "$root/block-couchdb-stop"
kill -TERM -- "-$first_pid"
if wait "$first_pid"; then fail 'terminated LiveSync capture succeeded'; fi
kill -0 "$blocked_pid" 2>/dev/null && fail 'LiveSync service-controller child survived TERM'
test ! -e "$root/ls-terminated/format-version" || fail 'terminated LiveSync capture published format marker'
wait "$second_pid" || fail 'waiting LiveSync capture failed after lock release'
test -f "$root/ls-concurrent/format-version" || fail 'waiting LiveSync capture did not publish'
test "$(cat "$root/couchdb.state")" = active || fail 'LiveSync TERM left CouchDB stopped'
pass 'LiveSync capture lock serialized overlap and process-group TERM resumed service'

mv "$root/couchdb" "$root/couchdb-hidden"
mkdir -m 700 "$root/ls-source-failure"
expect_failure 'LiveSync source capture failure' "$lsCapture" "$root/ls-source-failure"
test "$(cat "$root/couchdb.state")" = active || fail 'source failure left CouchDB stopped'
test ! -e "$root/ls-source-failure/format-version" || fail 'source failure published format marker'
mv "$root/couchdb-hidden" "$root/couchdb"

pass 'all recovery runtime checks'
