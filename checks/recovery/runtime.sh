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
mkdir -p "$root/vaultwarden/attachments" "$root/pg" "$root/socket"
chmod 700 "$root" "$root/pg" "$root/socket"

cleanup() {
  local status=$?
  trap - EXIT
  if test -f "$root/pg/postmaster.pid"; then pg_ctl -D "$root/pg" -m immediate -w stop || true; fi
  if test -f "$root/couchdb.pid"; then kill "$(cat "$root/couchdb.pid")" 2>/dev/null || true; fi
  if test "$status" -ne 0; then
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
# Disposable test control enables one prepared transaction; the production
# package/guard is unchanged and no live PostgreSQL setting is modified.
pg_ctl -D "$root/pg" -o "-c unix_socket_directories=$root/socket -c listen_addresses='' -c port=$pgPort -c max_prepared_transactions=1" -w start > "$out/pg-start.log" 2>&1
export PGPORT="$pgPort" PGHOST="$root/socket" PGUSER="$(id -un)" PGDATABASE=vaultwarden
createdb vaultwarden
psql -X -v ON_ERROR_STOP=1 -c 'CREATE ROLE vaultwarden LOGIN'
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
postgres_pid=$(head -n 1 "$root/pg/postmaster.pid")
printf 'linked file bytes\n' > "$root/vaultwarden/hardlink-a"
ln "$root/vaultwarden/hardlink-a" "$root/vaultwarden/hardlink-b"
test "$(stat -c %i "$root/vaultwarden/hardlink-a")" = "$(stat -c %i "$root/vaultwarden/hardlink-b")" || fail 'hardlink fixture was not linked'
pass "PostgreSQL $postgresVersion fixture seeded with linked attachment; source server remains running"

coproc APP_SESSION { psql -X --no-password -A -t --username=vaultwarden --dbname=vaultwarden; }
app_session_pid=$APP_SESSION_PID
printf '%s\n' '\echo app-session-ready' >&"${APP_SESSION[1]}"
IFS= read -r -t 20 readiness <&"${APP_SESSION[0]}"
test "$readiness" = app-session-ready || fail 'app-role backend did not become ready'
mkdir -m 700 "$root/vw-busy-backend"
expect_failure 'Vaultwarden existing idle app-role backend' "$vwCapture" "$root/vw-busy-backend"
test ! -s "$root/vw-busy-backend/pg-dump" || fail 'guard allowed an archive with app backend present'
test ! -e "$root/vw-busy-backend/format-version" || fail 'guard rejection wrote success marker'
printf '%s\n' '\q' >&"${APP_SESSION[1]}"
wait "$app_session_pid"
pass 'same production SQL rejects an idle app-role backend; fixture closes it without polling or sleeps'

psql -X -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
INSERT INTO users VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd');
PREPARE TRANSACTION 'apps-fixture-pending';
SQL
mkdir -m 700 "$root/vw-prepared-transaction"
expect_failure 'Vaultwarden session-independent prepared transaction' "$vwCapture" "$root/vw-prepared-transaction"
test ! -s "$root/vw-prepared-transaction/pg-dump" || fail 'guard allowed an archive with prepared transaction present'
test ! -e "$root/vw-prepared-transaction/format-version" || fail 'prepared transaction rejection wrote success marker'
psql -X -v ON_ERROR_STOP=1 -c "ROLLBACK PREPARED 'apps-fixture-pending'"
pass 'same production SQL rejects prepared activity after its client exits; fixture rolls back only its own transaction'

mkdir -m 700 "$root/vw-valid"
"$vwCapture" "$root/vw-valid"
test ! -e "$root/vw-valid/format-version" || fail 'data-only capture wrote lifecycle success marker'
cp -- "$vwFormatMarker" "$root/vw-valid/format-version"
cmp "$root/vaultwarden/hardlink-a" "$root/vw-valid/vaultwarden-app/hardlink-a"
cmp "$root/vaultwarden/hardlink-b" "$root/vw-valid/vaultwarden-app/hardlink-b"
test "$(stat -c %i "$root/vw-valid/vaultwarden-app/hardlink-a")" != "$(stat -c %i "$root/vw-valid/vaultwarden-app/hardlink-b")" || fail 'capture retained internal hardlinks'
test "$(stat -c %h "$root/vw-valid/vaultwarden-app/hardlink-a")" = 1 || fail 'copied file has shared links'
pass 'Vaultwarden foreground archive and independent file copies; fixture supplies validation marker'

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

psql -X -v ON_ERROR_STOP=1 -c "INSERT INTO users VALUES ('dddddddd-dddd-dddd-dddd-dddddddddddd')"
mkdir -m 700 "$root/vw-stopped"
"$vwCapture" "$root/vw-stopped"
cp -- "$vwFormatMarker" "$root/vw-stopped/format-version"
pg_restore --file="$out/initial-capture.sql" "$root/vw-valid/pg-dump"
pg_restore --file="$out/fresh-capture.sql" "$root/vw-stopped/pg-dump"
if grep -q dddddddd-dddd-dddd-dddd-dddddddddddd "$out/initial-capture.sql"; then fail 'initial archive contained future row'; fi
grep -q dddddddd-dddd-dddd-dddd-dddddddddddd "$out/fresh-capture.sql" || fail 'capture reused a stale archive'
pass 'Vaultwarden fresh database archive comes from the same running source PostgreSQL process'

touch "$root/fail-dump"
mkdir -m 700 "$root/vw-dump-failure"
expect_failure 'Vaultwarden foreground database dump failure' "$vwCapture" "$root/vw-dump-failure"
test ! -e "$root/vw-dump-failure/format-version" || fail 'dump failure wrote success marker'
test -s "$root/vw-dump-failure/pg-dump" || fail 'partial archive evidence disappeared'
rm "$root/fail-dump"

mv "$root/vaultwarden" "$root/vaultwarden-hidden"
mkdir -m 700 "$root/vw-copy-failure"
expect_failure 'Vaultwarden copy source failure after dump' "$vwCapture" "$root/vw-copy-failure"
test ! -e "$root/vw-copy-failure/format-version" || fail 'copy failure wrote success marker'
mv "$root/vaultwarden-hidden" "$root/vaultwarden"
test "$(head -n 1 "$root/pg/postmaster.pid")" = "$postgres_pid" || fail 'source PostgreSQL restarted during capture'
kill -0 "$postgres_pid" || fail 'source PostgreSQL no longer running'
psql -X -v ON_ERROR_STOP=1 -At -c 'SELECT count(*) FROM users' | grep -qx 2 || fail 'source query failed after captures'
pass 'data-only failure retains evidence; native lifecycle/teardown remains PREDEPLOY'

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
sed 's/^-setcookie .*/-setcookie disposablefixturecookie/' "$couchArgsFile" > "$root/vm.args"
cat >> "$root/vm.args" <<'EOF'
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
pass "CouchDB $couchdbVersion fixture seeded with linked LiveSync chunk"

mkdir -m 700 "$root/ls-valid"
"$lsCapture" "$root/ls-valid"
test ! -e "$root/ls-valid/format-version" || fail 'data-only capture wrote lifecycle success marker'
cp -- "$lsFormatMarker" "$root/ls-valid/format-version"
validate_sandbox "$lsValidate" "$root/ls-valid"
pass 'LiveSync foreground native capture and disposable CouchDB semantic validation'

start_couch
curl --noproxy '*' -fsS --max-time 5 -u fixture:fixture-password \
  -H 'Content-Type: application/json' -X PUT "$url/obsidian/f:broken-note" \
  --data-binary '{"type":"plain","path":"broken.md","children":["h:missing-chunk"],"eden":{}}' \
  > "$out/couch-broken.json"
stop_couch
mkdir -m 700 "$root/ls-missing-child"
"$lsCapture" "$root/ls-missing-child"
cp -- "$lsFormatMarker" "$root/ls-missing-child/format-version"
expect_failure 'LiveSync missing active chunk' validate_sandbox "$lsValidate" "$root/ls-missing-child"

cp -a "$root/ls-valid" "$root/ls-unsupported"
rm "$root/ls-unsupported/format-version"
printf '%s\n' unsupported > "$root/ls-unsupported/format-version"
expect_failure 'LiveSync unsupported format' validate_sandbox "$lsValidate" "$root/ls-unsupported"

mv "$root/couchdb" "$root/couchdb-hidden"
mkdir -m 700 "$root/ls-source-failure"
expect_failure 'LiveSync foreground source capture failure' "$lsCapture" "$root/ls-source-failure"
test ! -e "$root/ls-source-failure/format-version" || fail 'source failure wrote success marker'
mv "$root/couchdb-hidden" "$root/couchdb"
pass 'manager activity, inhibition, cancellation and descendant proof remain PREDEPLOY'

pass 'all recovery runtime checks'
