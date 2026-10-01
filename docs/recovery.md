# Native application exports and retained validation

## Native exports

Set `export.enable = true` on an active Obsidian or Vaultwarden selection, either
through `clanwright.apps.machines.<machine>` or its direct Clan recipe settings.
The default is false. This creates manually callable native services and command
outputs; it does not start captures or create timers, destinations or uploads.

| App | Capture service | Machine command output | Native state/root |
| --- | --- | --- | --- |
| Vaultwarden | `apps-export-vaultwarden.service` | `config.system.build.appsVaultwardenExport` | `apps-export-vaultwarden`: `/var/lib/clanwright-app-exports/vaultwarden` |
| LiveSync | `apps-export-livesync.service` | `config.system.build.appsLiveSyncExport` | `apps-export-livesync`: `/var/lib/clanwright-app-exports/livesync` |

Systemd owns preparation, foreground capture, publication and stop cleanup.
Generated stages use a persistent root-owned `0700` StateDirectory, native
deadlines and process teardown. An invocation-bound attempt record and activation
inhibit survive interrupted operations; there is no second executor or process
supervisor.

Start a service explicitly, or let the consumer provide a native timer. Capture
scheduling is separate from delivery: application resumption must complete before
publication and before reader copying or network operations. Prior active or
inactive state is recorded before the first service mutation. An unresolved
attempt blocks a new allocation until its teardown and resumption are confirmed.

Publication atomically replaces the relative `current` pointer under a bounded
exclusive lock. Before this commit, every failure preserves the old complete
export. Once the commit selects the new complete export, a later unit failure or
cancellation reports failure without rolling back that selection. Readers must
never observe a partial or mixed artifact. This does not promise power-loss
durability. Systemd result and journal report failures; a destination's last
upload time is not capture evidence.

Only exporter-owned, unselected data may be reclaimed, before the next allocation.
A pending attempt record selected by `current` must never be cleanup input.
Normal deactivation keeps `current`. Two producer-sized trees cover the selected
export and the next attempt, including transient/native workspace; independent
disk reader copies require additional capacity. Neither publisher nor its cleanup
owns reader directories. Their acceptance evidence is governed by the
[predeployment boundary](#acceptance-boundary).

Publication requires successful quiescent capture, confirmed descendant teardown
and verified restoration of the original application activity before writing
the completion marker and metadata. A bounded payload scan rejects links, special
files and multiply linked files; capture timestamps must be ordered nonnegative
integers before selecting the generation. Vaultwarden additionally rejects remaining
application database backends and prepared transactions before dumping. Semantic
import is a separate retained-validation operation and does not run before commit. A complete capture does not certify
semantic recovery, decryptability or runnable clients. The required semantic
checks remain in `bin/validate` and the ordinary capture/import fixture.

The CouchDB helper copies directly into pending, without another full capture
tree. Reserve full payload bytes plus its uncapped temporary path-list, filesystem
metadata and source-growth headroom. Retained validation needs additional copies
described below; the two-producer-tree bound is not a total-host storage cap.

### Native Restic readers

Each command output provides:

```text
bin/prepare-reader --max-age SECONDS ABSOLUTE_EMPTY_DIRECTORY
bin/validate ABSOLUTE_RESTORED_DIRECTORY
```

`prepare-reader` runs as root and accepts an existing empty root-owned `0700`
directory outside the export state tree. It resolves the published export and copies it while holding a shared
publication lock, then releases the lock before Restic runs. Copies share no
mutable files with the published export; reflinks are an optional optimization
with ordinary-copy fallback. Export roots and `current` are not direct Restic
inputs. The only supported input is a reader directory whose preparation exited
successfully. Failure can leave partial files, which the owning job must remove.

`--max-age` is mandatory and positive. Admission checks run before and after
copying and reject missing, malformed, future-dated or expired metadata. Age is
measured conservatively from the recorded attempt start, including the pause,
copy and restoration. It is an admission-age limit, not a maximum age on arrival at a
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

Native `services.restic.backups` wiring and reader ownership belong to the
consumer, such as [Clanwright Reliability](https://github.com/clanwright/reliability).
It consumes the configured `system.build` outputs and these public commands.
Each job needs an independent disk-backed reader, separate from Restic's own
cache, because Restic excludes its cache directory from snapshots. Full payloads
must not be placed in `/run` merely to obtain native cleanup.

The owning job establishes current-invocation ownership before preparation,
preserves foreign/pre-existing directories, and confirms every reader process
has stopped before removing owned input. Failed creation, partial preparation,
interruption, failed cleanup and leftovers require the same ownership proof.
A cleanup hook or control-group kill setting alone does not prove it. Apps
provides no backup-job constructor, cleanup adapter or Restic/provider dependency.

The consumer supplies destinations, credentials, schedules, retention, capture
admission/arrival policy and deadlines; its final native Restic job package is
the single authority for backup and checks. Two simultaneous destinations require
up to four export-sized trees per app: two producer-sized trees, including
transient/native workspace, plus two independent disk reader copies. Apps'
Vaultwarden capture uses no shared database staging. Storage capacity and I/O
remain shared even though network delays hold no publication lock. Retained
validation adds its separate input/database scratch budget below.

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
or a private validation handler directly.

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
input copy. The CouchDB validator additionally makes a writable full database
copy in that private scratch; PostgreSQL imports its archive into disposable
database files. Account for database writes, logs and semantic page files as well.
Page limits bound rows, not bytes. These coexist with the original restored input,
producer generations, reader copies and retained failed scratch. Provision all
of them before starting; no reflink saving is assumed. For same-host use, reserve
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

## Public boundary

Apps exposes only the opt-in native export services and the matching reader and
retained-validator packages listed above. It does not declare
`clanwright.recovery.units` or import the public Primitives recovery schema.
Consumers of the retired `captureCommand`/`validateCommand` executor interface
must adopt native service starts and these packages; no compatibility adapter is
provided. Application-specific handlers and their records remain private
implementation details. Internally, Apps requires the package-valued Primitives
SDK `mkRecoveryTools { pkgs = ...; }`: the effective database packages are passed
explicitly to the PostgreSQL/CouchDB factories, and semantic checks are package
callbacks. Caller `pkgs` supplies native glue. Database executables, configuration
and DB-specific runtime components must come from the effective selected package;
a matching disposable fixture from another nixpkgs cohort does not qualify the
actual recipe. `mkCouchdbRecovery` also requires an explicit `erlang` package for
native EPMD. For the unmodified public Primitives CouchDB module, Apps passes
`primitives.inputs.nixpkgs.legacyPackages.${system}.beamMinimalPackages.erlang`
from that same Primitives artifact. Primitives checks native CouchDB override
replay against both original derivation and output identity; the original effective
DB remains the executable/config authority. Component-changing native overrides
need their explicitly selected component. Arbitrary or argument-ignoring custom
factories are unsupported; no caller-package fallback or universal override
guarantee is provided. Consumers must use compatible published inputs; see the
[dependency and release contract](../README.md#dependencies-and-migration).

The physical state identities remain `vaultwarden-app`, `vaultwarden-db`,
and `obsidian`; native export IDs remain `vaultwarden`
and `livesync`. No backup timer, provider, retention policy or destination is
added by enabling an export.

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
and writes a fresh native custom database archive plus independent application
files during the same pause. Root opens the private archive output before the
native postgres actor writes through the inherited descriptor. The effective
PostgreSQL package and port are used; the socket is explicitly `/run/postgresql`.
Capture children terminate before restoring the original application activity.
Before dumping, one bounded native PostgreSQL query rejects remaining
application-role sessions and prepared transactions for the application database.
Stopping the app process alone does not prove its previously submitted server
queries have finished. A busy or uncertain result fails capture; Apps neither
polls nor terminates database backends.
LiveSync pauses CouchDB while its public
helper copies the database set and view indexes. Initially inactive services
remain inactive. Failed preparation, copying or cleanup cannot produce a
successful recovery point.
LiveSync uses the pinned native node identity `couchdb@127.0.0.1`. A custom
`services.couchdb.argsFile` is rejected because a different source node requires
a matching, explicitly reviewed recovery handler.

## Capture permissions and termination budget

Capture unit start time is bounded to one hour. Both exporters use a six-minute
stop budget and `KillMode=control-group`, forced termination, no restart and no
delegation. Foreground capture descendants must stop before finalization restores
the app or removes unselected data. Capture has production privileges; reader
jobs receive completed export access, and validators receive isolated restored data.

Capture is a privileged host operation. The root-owned native capture service
reads the application's state folders and writes its operation-private pending
directory. Its persistent `producer.lock` serializes phase entry; the native unit
and owned attempt record serialize the whole operation across phase boundaries.
Vaultwarden additionally
needs local PostgreSQL socket access as the existing native OS/DB `postgres`
identity, and the native tools' user lookup and privilege-switch facilities.
No database password prompt or password-file credential is used. Each native capture service needs permission to query, stop
and start its application service through the local service manager. These
permissions belong only to capture; never expose them to validation.

Each Vaultwarden dump writes operation-private output, with no shared Clan
staging/preparation/cleanup. Automatic app activation is inhibited during capture.
Do not concurrently manage the application unit or introduce another database
writer during capture. Inhibition and the PostgreSQL guard do not prevent a
privileged administrator from deliberately changing that boundary.

Service queries are bounded to 20 seconds, stop/start to
60 seconds each, and individual dump/copy steps to 600 seconds each.
Timed commands have a further 5-second kill allowance. The finalizer's bounded
manager calls, publication lock and possible reclaims total at most 290 seconds,
leaving native service overhead within the six-minute stop budget. Preserve that
budget. An uncertain manager/cgroup result, interrupted ownership or incomplete
cleanup retains the attempt and activation inhibit, blocking later producer
phases and invocations. Inspect the exact owned attempt, native unit and cgroups
before operator recovery; do not delete its record, inhibit or payload to bypass
the barrier. A selected `current` generation is never cleanup input. SIGKILL,
host failure and failed app restoration cannot promise automatic resumption.

## Semantic acceptance

`bin/validate` imports disposable databases and checks the application-specific
cross-store invariants below. It does not start Vaultwarden or an Obsidian
LiveSync client and does not prove runnable-application acceptance, production
restoration or successful client synchronization.

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
relationships, including surviving conflicting metadata revisions.
Documents are read in pages of 32 with a 30-second request
deadline. Payload strings are reduced to type evidence before the relationship
check; its metadata index still grows with the number of documents. The wrapper's
overall deadline and memory limit remain unchanged. An empty
`obsidian` database, unused chunks and deleted documents are valid
cases. It does not decrypt user content or assert plaintext file paths.
An artifact without the `obsidian` database is rejected as an uninitialized
LiveSync namespace.
See the upstream [data structure](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/datastructure.md)
and [garbage collection guidance](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/troubleshooting.md).
Server-side structural validation cannot prove decryption with a user's keys or
successful synchronization by a particular Obsidian client.

## Lifecycle, historical backups and migration

Only enabled, opted-in recipes publish native capture services and command
packages. `disabled-retained` preserves state and secret metadata, including
opted-in export state, but withdraws runtime, ingress and runnable exporters.
Turning exports off or setting the selection to `null` performs no filesystem
deletion; null also withdraws declarations. These changes never authorize deletion
of historical backups.

Before disabling, removing or upgrading a producer, retain its pinned
configuration and compatible validator closure under a separate GC root. Preserve
application/database versions, extensions and restoration policy. Retained state
and the `validatorStorePath` metadata string do not preserve a closure; metadata
is provenance and never chooses executable input.

Same-host validation requires a matching wrapper with the supported envelope
above. Older wrappers that require a disposable validation host retain that
restriction; do not wrap or invoke their bare handlers on the application host.
Retain the supported `config.system.build.appsVaultwardenExport` or
`appsLiveSyncExport` closure after adopting a release. Compatible validators can
validate historical captures without `export.json`; readers require publication
metadata and do not silently treat those captures as new exports. Existing
`formatVersion` markers remain authoritative. A new format requires a compatible
old handler or an explicitly tested migration; never relabel an artifact to
bypass its version check.

The database baseline is PostgreSQL 18.6 and CouchDB 3.5.2; Apps supplies
Vaultwarden 1.37.3. PostgreSQL 17 backups and directories are not implicitly
accepted by the PostgreSQL 18 helper. Keep the old environment and perform a
separately tested migration before adopting the new database major, as described
in [dependencies and migration](../README.md#dependencies-and-migration).
When adopting the current Obsidian recipe from a legacy direct declaration,
replace `@clanwright/apps-livesync` with `@clanwright/apps-obsidian` and update
instance references to `<machine>--app-obsidian`. Update state references from
`livesync-couchdb` to `obsidian`; CouchDB data remains under `/var/lib/couchdb`.
The administrator INI binding defaults to `obsidian-admin-ini`: prepare that
existing SOPS binding before activation, or explicitly set `adminConfigSecretName`
to the preserved binding. Rename declarations and references without moving or
deleting application data or regenerating credentials. The stable recovery ID
remains `livesync`; Vaultwarden's state, secret and recovery identities are unchanged.

## Acceptance boundary

Available source evidence consists of independent review, pure Nix evaluation,
standalone Clan composition, package builds, and ordinary native process,
database and tool checks. Release gates use the final compatible published input
graph. No new VM, test host or privilege/credential workaround is part of these
gates. Actual manager/root-peer, same-host, reader lifetime and network behavior
require the native evidence below; their deferred observation does not block
source acceptance or release publication.

With appropriate Linux builders and compatible pinned inputs, run the retained
ordinary checks and preserve their readable output (choose native recovery-runtime
architecture as appropriate):

```sh
mkdir -p state
nix build --no-link --print-out-paths \
  .#checks.x86_64-linux.contract \
  .#checks.x86_64-linux.http-runtime \
  .#checks.aarch64-linux.recovery-runtime \
  .#checks.aarch64-linux.export-tools \
  > state/recovery-checks.log 2>&1
```

`contract` evaluates actual recipe declarations, lifecycle withdrawal/retention
and shared Network composition. `http-runtime` uses a local Caddy/backend fixture,
without a real application database. `export-tools` builds the reader/validator
packages and native stages. `recovery-runtime` checks disposable database
capture/import and semantic invariants through the public Primitives SDK with a
substituted database actor. Its caller glue and effective DB packages are selected
through public Clan/Primitives module evaluation; package/component identities
must agree with the corresponding recipe cohort. A disposable-only prepared
transaction setting enables the session-independent writer rejection control.
It exercises idle app-role and prepared-transaction rejection followed by
fresh capture/import, regular independent copies and the semantic checks; it
does not simulate manager acceptance. It retains `check.log` and fixture
diagnostics in its output. Run it on the builder's native supported architecture;
an ARM pass does not prove native x86 execution or add an ARM Vaultwarden package
export. Unsupported/emulated execution must be reported explicitly, never as a
native runtime pass. Fresh nested-consumer locking and coordinated upgrade checks
are described in the [README](../README.md#verification-and-release-acceptance).

Use one joint Apps/Reliability acceptance matrix; do not duplicate the database
suite in Reliability. Record the tested revision/input closures, actual runner,
commands, outcomes and readable artifacts for each row. Review, evaluation,
theoretical flags and historical results are not runtime PASS. The following
rows are **PREDEPLOY / NOT OBSERVED: mandatory before deployment for the
current source**. No root/systemd runner is currently available for these paths;
historical observations cannot certify changed code:

| Native boundary | Required evidence |
| --- | --- |
| Publication and readers | Overlapping publication/readers; independent destination A/B copies; nested-input rejection; invalid payload shape/links and backwards clock fail before commit; failed captures preserve original age; every precommit failure preserves old complete, while postcommit failure/cancellation retains new complete; selected current survives stale pending status and normal deactivation; copying finishes under lock before reclaim of only owned unselected data; reclaim before next allocation and actual two-producer payload/workspace peak |
| Native Restic composition | All four actual jobs upload while capture can continue; restored copies validate with retained matching closures; success, upload exit 3/error, partial preparation and cancellation with descendants; postStart cancellation; foreign/pre-existing reader, failed mkdir/partial creation/interruption before ownership evidence; cleanup failure followed by next attempt; independent A/B ownership; actual process stop before reader deletion |
| Actual capture | Root-to-postgres peer authentication and private output descriptor; native activation inhibition and manager/database quiescence; prior active/inactive state recorded before mutation; pre/post failure and TERM preserve or restore that state; unresolved attempts block every producer phase/instance and allocation; failure to restore retains the barrier |
| Same-host continuity | Continuous HTTP checks, unchanged MainPID/InvocationID, live SQL/CouchDB data and file hashes while both validators process restored copies |
| Sandbox boundary | UID/GID 65534, zero capabilities, cleared environment, no host credentials or inherited FD 9, null stdin, read-only input/store, loopback-only network and descendant isolation; private modes; rejection of links and FIFO/special files |
| Whole-operation bounds and admission | Effective preparation plus execution MemoryMax 1 GiB, swap 0, TasksMax 128, CPUQuota 100%, nice 10 and IOWeight 10; host-wide cross-app admission; launcher SIGKILL does not release the barrier prematurely |
| Failure and uncertain teardown | Timeout, caller TERM, killed monitor, handoff error, cancellation before creation, foreign-unit refusal and populated/uncertain cgroup preserve scratch and ownership until confirmed teardown |
| Native network and authentication | Stable certificate identities/readers and host ACME authority; actual Caddy startup gate under its service UID/sandbox, listeners/TLS and atomic failed reload retaining prior routes; real Vaultwarden error records/trusted-proxy parsing, journal ingestion and Fail2ban enforcement; unsafe request/auth free strings absent from configured HTTP-error sinks |

Actual predeployment execution must observe all rows on the intended native
manager using the same public packages and consumer composition. A test
definition, source review or ordinary process fixture cannot close them.
Standalone checks do not prove production DNS, certificates, firewall packet
behavior, live client traffic, database-major migration, production restoration,
or acceptance of a particular backup destination. Keep pinned configuration and
matching retained validator closures separately from backup metadata. The current
policy is recorded in [ADR 0004](adr/0004-source-and-predeployment-acceptance.md).
