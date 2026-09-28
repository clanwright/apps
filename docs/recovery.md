# Application recovery contract

## Native exports

Set `export.enable = true` on an active Obsidian or Vaultwarden selection, either
through `clanwright.apps.machines.<machine>` or its direct Clan recipe settings.
The default is false. This creates manually callable native services and command
outputs; it does not start captures or create timers, destinations or uploads.

| App | Capture service | Machine command output | Native state/root |
| --- | --- | --- | --- |
| Vaultwarden | `apps-export-vaultwarden.service` | `config.system.build.appsVaultwardenExport` | `apps-export-vaultwarden`: `/var/lib/clanwright-app-exports/vaultwarden` |
| LiveSync | `apps-export-livesync.service` | `config.system.build.appsLiveSyncExport` | `apps-export-livesync`: `/var/lib/clanwright-app-exports/livesync` |

Systemd owns the operation: `ExecStartPre` prepares an empty private staging
directory, `ExecStart` directly runs the existing application capture handler,
`ExecStartPost` publishes the completed artifact, and `ExecStopPost` removes
unfinished staging. State and runtime directories are root-owned, mode `0700`.
There is no second executor, process supervisor or status ledger.

Start a service explicitly, or let the consumer provide a native timer. Do not
trigger a new capture independently from each destination's preparation hook:
capture scheduling is separate from delivery, and production resumes before any
reader copy or network operation begins. The service serializes its own starts;
the existing capture lock also protects compatible command callers.

Publication replaces a relative `current` pointer atomically under a bounded
exclusive lock. Readers cannot observe a partial or mixed artifact. This does
not promise durability across power loss. A failure before publication preserves
the previous export. If publication succeeds but later reclamation fails, the
new completed export remains usable and the service reports failure. Systemd
result and journal are failure evidence; never infer successful capture solely
from a destination's last upload time. Interrupted staging and noncurrent
exporter-owned leftovers are reclaimed on a later capture. Neither publisher nor
its cleanup owns reader directories.

### Native Restic readers

Each command output provides:

```text
bin/prepare-reader --max-age SECONDS ABSOLUTE_EMPTY_DIRECTORY
bin/validate ABSOLUTE_RESTORED_DIRECTORY
```

`prepare-reader` runs as root and accepts an existing empty root-owned `0700`
directory. It resolves the published export and copies it while holding a shared
publication lock, then releases the lock before Restic runs. Copies share no
mutable files with the published export; reflinks are an optional optimization
with ordinary-copy fallback. Export roots and `current` are not direct Restic
inputs. The only supported input is a reader directory whose preparation exited
successfully. Failure can leave partial files, which the owning job must remove.

`--max-age` is mandatory and positive. Admission checks run before and after
copying and reject missing, malformed, future-dated or expired metadata. Age is
measured conservatively from capture start, including any wait for the existing
capture lock. It is an admission-age limit, not a maximum age on arrival at a
slow destination. Publication-lock waits are bounded to 30 seconds and copying
to 600 seconds plus a 5-second forced-termination allowance. Contention can
cause a visible missed capture/publication; ordinary flock does not promise
writer fairness.

Every export carries `export.json` schema version 1: `appId`, `captureId`,
`captureStartedAt`, `captureCompletedAt` (integer Unix seconds), `formatVersion`
and `validatorStorePath`. This supplements the unchanged owner format marker.
Reader copies and retries preserve that metadata. A later Restic snapshot of an
old export is an additional delivery of the same recovery point, not a fresh
capture. Keep the last successful export available after a failed capture while
its original age meets the consumer's limit. The recorded validator path is
provenance, not executable input or a GC root.

The [consumer example](../examples/native-restic.nix) composes four independent
`services.restic.backups` jobs: each app to two destinations. It stores private
copies below each job's `CacheDirectory`, not in `/run`.
Restic cache files live in a separate `cache` child beside `apps-input`, because
Restic automatically excludes its own cache directory from snapshots.
The native `backupPrepareCommand` obtains the copy and `backupCleanupCommand` removes it
after process teardown, including failed preparation or upload. Next-start
cleanup handles leftovers after host loss. Start these jobs through systemd;
the example disables direct wrapper creation to preserve that lifecycle.

The example explicitly uses `timerConfig = null`, because the NixOS Restic
module otherwise defaults to daily timers. The consumer supplies destinations,
credentials, schedules, retention and policy values (the example uses a one-day
capture-age limit and a two-hour job deadline). Apps does not import Restic or
provide a destination abstraction. Two simultaneous destinations require up to
four export-sized trees per app, including capture staging and the published
export, plus native database-helper staging. Storage capacity and I/O remain
shared resources even though network delays hold no publication lock.

### Validation on an existing application host

Invoke `bin/validate` from a separately retained matching command closure as
root on a Linux host with its local systemd system manager and cgroup
v2 hierarchy. The existing application host is supported when it meets the
resource and storage prerequisites below; a separate VM is not required. The caller must share the manager's mount and cgroup namespaces;
calling from a container connected to host D-Bus is unsupported.
Supply a quiescent, administrator-controlled,
root-owned restored directory, including trusted parent directories; do not
point it at production state. Nested mounts and concurrent hostile filesystem
mutation are unsupported. Symbolic links, hard-linked files and special files
are rejected. The source is left unchanged.

The wrapper supplies disk-backed private scratch, an ordinary disposable copy
readable by the sandbox identity, read-only input and Nix store, private writable
temporary storage, isolated PID/network/IPC/UTS namespaces with loopback, and a
store-backed `/bin/sh`. It clears inherited environment and extra file
descriptors. The semantic validator runs with real UID/GID 65534, no supplementary
groups or capabilities and no privilege escalation. Host `/etc`, production
state, service sockets and credentials are not mounted into the sandbox. The
trusted retained closure chooses the executable; restored metadata never does.

Preparation and semantic execution share a native transient systemd service,
`apps-validate.service`, and one operation budget. Admission is host-wide across
both applications: overlapping calls fail rather than queue. This bound applies
to these updated retained wrappers; do not concurrently invoke an older wrapper
or the bare `validateCommand`.

The fixed resource envelope covers input scanning, copying, permission handoff,
and the isolated database processes:

| Control | Bound |
| --- | --- |
| CPU | `CPUQuota=100%` (one CPU worth of time), nice level 10 |
| Memory | `MemoryMax=1G`, `MemorySwapMax=0`, `OOMPolicy=kill` |
| Processes and threads | `TasksMax=128` |
| I/O priority | `IOWeight=10`; relative weight, not a bandwidth or latency cap |
| Service preparation and validation | `TimeoutStartSec=600s`, with `TimeoutStopSec=30s` for teardown |

The host must have functional cgroup v2 CPU, memory and PID controllers and
sufficient capacity left for its running applications. The cap is a maximum,
not a reservation for either workload. An artifact that cannot be validated
within this envelope fails; it does not justify retrying with an unbounded bare
handler on production.

**Storage prerequisite:** scratch uses `/var/tmp`, containing a full independent
input copy plus disposable database/import files. Provision capacity for both
and for retained failed attempts before starting. For same-host use, reserve
scratch capacity on a separate filesystem or with an administrator-managed
quota so exhaustion cannot consume application storage. The command does not
provision storage, set quotas, or bound aggregate file bytes. CPU/memory/task
limits and I/O weight do not isolate shared kernel faults, storage latency,
filesystem failure or uninterruptible I/O. A host needing protection from those
shared failure domains still needs a separate validation host.

The transient unit uses `Type=oneshot` and `RemainAfterExit=yes`: completion
retains its native slot until the wrapper confirms teardown. Its unique native
description identifies the caller allowed to stop it. `KillMode=control-group`,
forced termination, no restart and no delegation cover detached descendants.
The wrapper prints captured validator output after the service returns; inspect
the printed scratch directory and journal while it is running.
The launcher has a separate 660-second bound plus a 5-second kill allowance;
individual manager calls have 40 seconds plus 5 seconds. These control-plane
budgets are additional to the service budget, not a promise that the CLI returns
within 600 seconds. Catchable cancellation requests native stop and waits for
the bounded launcher before checking teardown. Uninterruptible kernel I/O may
outlive any userspace deadline; it never authorizes cleanup.

Success removes scratch only after stopping the owned unit and confirming both
terminal manager state with no pending job and an absent or empty cgroup.
Semantic failure, timeout and cancellation return failure and retain the printed
root-only scratch directory. When the wrapper explicitly reports **teardown
confirmed**, the administrator may remove that exact directory without reboot;
the wrapper releases the native slot for another validation. A failed validation
is never reported as successful because cleanup succeeded.

For **handoff or teardown unconfirmed**, or a caller killed with SIGKILL, preserve
scratch and inspect `apps-validate.service`. An unkillable process or missing
manager evidence is not permission to remove files or reset native failure
state. Do not retry automatically. For manual recovery, serialize with the same
`/run/lock/apps-validate.lock`, identify the unit by its printed scratch/token and
native description, request a bounded native stop, then verify terminal state,
no pending job and an absent cgroup or `populated 0` in its `cgroup.events`.
Only after that proof may an administrator reset the failed unit and remove its
exact retained scratch. Unknown or delayed submission also requires establishing
that the launcher has finished and the manager has processed it; disappearance
of the caller alone is insufficient. If these facts cannot be established,
leave the slot and data untouched and diagnose the host. A reboot may be an
operator's last-resort remedy for a broken kernel/manager; the validator never
requests one, and it is not part of normal cleanup.

There is no custom process supervisor, background cleanup daemon or
directory-scanning registry.


Capture unit start time is bounded to one hour. Stop budgets are 180 seconds for
Vaultwarden and 90 seconds for LiveSync; direct handler execution and
`KillMode=mixed` preserve their existing cleanup/resumption path before final
forced termination. The existing handler requirements and limits below still
apply. Capture needs privileged source and service-manager access; native reader
jobs need only completed export access, and isolated validators receive no
production privileges.

### Lifecycle and compatibility

`disabled-retained` preserves opted-in native export state while withdrawing
runnable exporters and command outputs. Turning exports off or selecting `null`
does not delete local data or historical backups. Retain the matching validator
closure under a GC root and keep the pinned configuration before disabling,
removing or upgrading an app. Merely recording a store path in metadata does
not preserve the closure.

The v0.4.0 wrapper continues to require a disposable validation host. Same-host
support requires the updated wrapper closure, not a consumer-side wrapper around
the old command. No recipe option or invocation change is needed. Retain the
new `config.system.build.appsVaultwardenExport` or `appsLiveSyncExport` closure
under a GC root after adopting the release. A matching updated validator can
validate the unchanged v0.4.0 artifact formats, including historical captures
without `export.json`. Metadata's `validatorStorePath` is never executed.

Existing artifact formats remain unchanged. Historical captures without
`export.json` can be checked by a compatible validator but are not silently
admitted as newly published exports. Database-major migrations remain separate
operations; the PostgreSQL 17/18 requirements below still apply.

## Existing application-owned command interface

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
  .#checks.aarch64-linux.recovery-runtime \
  .#checks.aarch64-linux.export-tools \
  .#checks.aarch64-linux.validator-isolation \
  .#checks.aarch64-linux.export-runtime \
  > state/recovery-checks.log 2>&1
```

`export-tools` builds the public reader/validator packages and native stage
scripts. `validator-isolation` exercises the privileged-to-unprivileged handoff,
namespace and descriptor isolation, effective preparation/execution resource
limits, cross-application admission, cancellation, caller death and descendant
cleanup in a disposable ARM Linux VM. `export-runtime` uses an ARM test driver with a complete
x86_64 Linux VM, because the current Network host composition supports x86_64
only. It imports the actual Clan machine module and the shipped native Restic
example. TCG emulation is used when hardware acceleration is unavailable; report
that boundary explicitly rather than calling it native x86 hardware evidence.
The same-host scenarios use Nix-defined shell fixtures with the existing NixOS
test driver. They check HTTP availability, service identity and live fixture
data while the public validator processes restored copies, including rejection
of an unsupported format. These test definitions do not themselves establish
a passing runtime result.

The recovery runtime derivation retains a readable `check.log` and fixture
diagnostics in its output. Its databases and service controller are disposable;
it invokes the same owner factories and public Primitives commands as the
recipes. The composition check verifies the actual native recipe declarations.
`checks.aarch64-linux.recovery-runtime` runs the same suite natively on ARM Linux;
this does not add an ARM Vaultwarden package export. Use the runtime check that
matches the builder's native architecture.

For the separate x86 `recovery-runtime` derivation under user-mode emulation on
the current ARM-hosted builder, x86 Erlang's default JIT mapping fails before
CouchDB can start (`prim_tty`/`nouser`). A test-source-only single-mapping JIT probe
starts, but the public isolated helper clears that test flag. Native ARM runtime
evidence must not be described as native x86 runtime acceptance. The release
gate uses the complete recovery suite on a native supported Linux builder;
native x86 runtime is an additional check, not a mandatory release gate.
That user-mode emulated x86 check is not a release gate; the complete-VM
`export-runtime` integration check above remains required. The test
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
