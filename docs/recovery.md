# Application recovery contract

Apps publishes two application-owned units through Primitives v0.2.0, revision
`9dd13dd84479914fe8465ff6f77d2bb1f8034e2e`. The interface is
`clanwright.recovery.units.<id>` with `contractVersion = 1`, `formatVersion`,
`stateRefs`, `captureCommand`, and `validateCommand`.

| ID | Recipe | Native state references |
| --- | --- | --- |
| `vaultwarden` | Vaultwarden | `vaultwarden-app`, `<database-name>-db` |
| `livesync` | Obsidian LiveSync | `obsidian` |

The default database name is `vaultwarden`. The recipe owns these declarations;
the executor selects stable IDs and invokes commands without knowing database
tables or duplicating native state paths. No Reliability import, backup timer,
provider, retention policy or destination is added by declaring a unit.

Apps supplies a shared, revision-qualified import of the recovery schema for
both recipes. Consumers using Apps do not need another direct import of
`primitives.nixosModules.recovery`. Independently importing the unkeyed schema
again can cause a duplicate option declaration; verify shared module identity
when composing other producers or executors.

## Stored formats

| Unit | `formatVersion` | Artifact contents |
| --- | --- | --- |
| Vaultwarden | `vaultwarden-pg18-files-v1` | `format-version`, PostgreSQL custom archive `pg-dump`, regular application tree `vaultwarden-app/` |
| LiveSync | `livesync-couchdb3-v1` | `format-version`, the public Primitives CouchDB capture artifact under `couchdb/` |

The owner marker is written only after capture cleanup and application resumption
succeed. The native CouchDB artifact retains its own helper version marker;
Apps does not redefine that private helper layout. Preserve complete artifacts,
including attachments and indexes captured by the public helper. Neither unit
uses links back into production state.
Vaultwarden normalizes copied ownership and read permissions inside the private
output directory so validation does not require the production service UID.
Production restoration must separately apply the destination service's ownership
and permissions; these commands do not restore production files.

Vaultwarden pauses only the application writer, leaves PostgreSQL available,
runs native Clan preparation, and copies the completed database archive and
application files during the same pause. Native cleanup runs before restoring
the original application activity. LiveSync pauses CouchDB while its public
helper copies the database set and view indexes. Initially inactive services
remain inactive. Failed preparation, copying or cleanup cannot produce a
successful recovery point.
LiveSync uses the pinned native node identity `couchdb@127.0.0.1`. A custom
`services.couchdb.argsFile` is rejected because a different source node requires
a matching, explicitly reviewed recovery handler.

## Invocation and isolation

`captureCommand ABSOLUTE_EMPTY_OUTPUT_DIRECTORY` receives an existing empty
private directory. A successful exit means the complete immutable local
generation exists and the application has returned to its prior service state.
Any nonzero exit is unpublishable. Upload must happen only after capture returns.
The executor must serialize captures of the same state and grant only the
documented local capture permissions. It supplies no repository credentials.

`validateCommand ABSOLUTE_RESTORED_DIRECTORY` rejects unsupported formats before
import, creates disposable databases and checks application relationships. It
does not execute native production restore hooks or start the actual application.
Production data, service sockets, credentials, mail and webhook configurations
are not required. The executor supplies read-only restored data (conventionally
`/input`), read-only `/nix/store`, private writable `/tmp`, a private PID/network
namespace with loopback, and an unprivileged user with no inherited environment.
Its restored copy, including the root directory, database archive and markers,
must be readable/traversable by that account. Capture preserves a private
`0700` root; a read-only bind alone does not perform a root-to-user ownership
handoff. Copy or adjust permissions on the disposable restored copy before
entering the sandbox, without exposing production state.
It must also supply `/bin/sh` as a symlink to a Nix-store shell as required by
the public Primitives PostgreSQL helper. Do not bind the host `/bin` or `/etc`.
The executor is responsible for final child teardown and scratch disposal.

`reliability-manifest.json` is reserved for executor metadata. Interface version,
stored artifact format and Apps release version are distinct. Executor metadata
does not replace the owner format marker. Neither command receives production
backup credentials, and validators use only disposable database authentication.

### Capture permissions and termination budget

Capture is a privileged host operation. Grant read access to the folders resolved
from the unit's `stateRefs`, and write access to the private output directory and
the corresponding `/run/lock/apps-<unit>-recovery.lock`. Vaultwarden additionally
needs native PostgreSQL preparation/cleanup permissions for its declared database
staging state, local PostgreSQL socket access, and the native tools' user lookup
and privilege-switch facilities. Both commands need permission to query, stop
and start their own systemd service through the local service manager. These
permissions belong only to capture; never expose them to validation.

The app capture lock serializes Apps callers. The consumer must also serialize
any other native PostgreSQL capture callers sharing the same staging state;
an Apps lock cannot control an independent backup job. Do not run another
service-management operation concurrently with a capture's activity check and
pause/resume sequence.

Service queries are bounded to 20 seconds, stop/start and native cleanup to
60 seconds each, and individual preparation/copy steps to 600 seconds each.
Timed commands have a further 5-second kill allowance. Reserve at least
135 seconds for Vaultwarden cleanup and 70 seconds for LiveSync cleanup after
catchable termination, plus executor overhead. The executor must not SIGKILL
the handler before that grace expires. Handlers terminate and reap capture
children before resuming writes. Repeated catchable signals are ignored during
cleanup. SIGKILL, host failure and a systemd service that cannot restart require
operator recovery; no shell handler can guarantee resumption in those cases.

## Semantic acceptance

Vaultwarden validation imports the database and checks relationships between
users/organizations, ciphers and attachments, including the stored attachment
files. Encrypted attachment names are display metadata; physical files use the
cipher and attachment IDs. A schema-correct empty installation is valid.
The source contract is [Vaultwarden 1.37.3's schema](https://github.com/dani-garcia/vaultwarden/blob/1.37.3/src/db/schema.rs)
and [attachment model](https://github.com/dani-garcia/vaultwarden/blob/1.37.3/src/db/models/attachment.rs).
Vaultwarden's [two-step upload API](https://github.com/dani-garcia/vaultwarden/blob/1.37.3/src/api/core/ciphers.rs)
creates an attachment row before receiving its bytes and has no persisted
pending/completed discriminator. Validation therefore conservatively rejects a
missing file, including an unfinished or abandoned upload. That discrepancy is
not proof that a completed attachment was lost. Resolve it through application
policy before accepting the recovery point; the validator never deletes records
or silently ignores missing data.

LiveSync validation reads the restored `obsidian` database and checks document/chunk
relationships, including surviving conflicting metadata revisions. An empty
`obsidian` database, unused chunks and deleted documents are valid
cases. It does not decrypt user content or assert plaintext file paths.
An artifact without the `obsidian` database is rejected as an uninitialized
LiveSync namespace.
See the upstream [data structure](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/datastructure.md)
and [garbage collection guidance](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/troubleshooting.md).
Server-side structural validation cannot prove decryption with a user's keys or
successful synchronization by a particular Obsidian client.

## Lifecycle, historical backups and migration

Only enabled recipes publish capture units. `disabled-retained` preserves state
and secret metadata but withdraws runtime, ingress and recovery declarations.
Setting the selection to `null` withdraws declarations. An executor selecting a
missing ID must fail explicitly; absence never authorizes deletion of historical
backups.

Before changing versions or removing a producer, retain its pinned configuration
and compatible validator closure in a separate recovery environment. Root those
closures against garbage collection and preserve application/database versions,
extensions and restoration policy. Retained state on its own is not a preserved
validator. A new format requires a compatible old handler or an explicitly tested
migration; do not relabel an older artifact to bypass its version check.

The current dependency baseline is Vaultwarden 1.37.3, PostgreSQL 18.6 and
CouchDB 3.5.2. PostgreSQL 17 backups and data directories from Apps v0.1.0 are
not implicitly accepted by the PostgreSQL 18 helper. Keep the old environment
and perform a separately tested migration before adopting the new database
major. The earlier state rename from `livesync-couchdb` to `obsidian` does not
change the stable recovery ID `livesync`; see the README for state and secret
binding migration.

## Acceptance boundary

With native Linux builders, run the public-interface checks explicitly:

```sh
mkdir -p state
nix build --no-link --print-out-paths \
  .#checks.x86_64-linux.contract \
  .#checks.x86_64-linux.http-runtime \
  .#checks.x86_64-linux.recovery-runtime \
  > state/recovery-checks.log 2>&1
```

The recovery runtime derivation retains a readable `check.log` and fixture
diagnostics in its output. Its databases and service controller are disposable;
it invokes the same owner factories and public Primitives commands as the
recipes. The composition check verifies the actual native recipe declarations.
`checks.aarch64-linux.recovery-runtime` runs the same suite natively on ARM Linux;
this does not add an ARM Vaultwarden package export. Use the runtime check that
matches the builder's native architecture.

On the current ARM-hosted builder, x86 Erlang's default JIT mapping fails before
CouchDB can start (`prim_tty`/`nouser`). A test-source-only single-mapping JIT probe
starts, but the public isolated helper clears that test flag. Native ARM runtime
evidence must not be described as native x86 runtime acceptance. A release
targeting x86 still needs the runtime check on a native x86 builder. The test
source CouchDB uses a store CA bundle through Erlang configuration; this
configuration is not inherited by the isolated validator.

Standalone composition and disposable runtime tests do not constitute a
production restore, deployment or acceptance of a particular backup executor.
Reliability v0.1.0's public documentation describes a private validation sandbox
but does not establish compatibility with these handlers' `/bin/sh` requirement
or capture cleanup budget. Verify those details and the root-to-unprivileged
handoff in the consumer before commissioning. Keep pinned configuration and
handler closures separately because its v1 manifest does not record owner-release
provenance automatically.
