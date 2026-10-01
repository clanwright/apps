# Native exports with independent reader copies

Status: accepted and implemented for v0.4.0; disposable runtime acceptance passed.

This status describes the historical revision. Current source verification and
mandatory unobserved PREDEPLOY coverage follow
[ADR 0004](0004-source-and-predeployment-acceptance.md).

For [Apps #4](https://github.com/clanwright/apps/issues/4), Apps publishes
completed application exports and give each independent backup reader its own
private local copy. A reader holds the publication lock only while obtaining its
copy, then releases it before any destination or network operation. Capture and
application resumption finish before publication. This keeps destination latency
out of application downtime and allows subsequent exports while uploads run.

Apps owns consistent capture, complete-only publication and semantic restore
validation. The consumer owns native Restic jobs, destinations, credentials,
schedules, maximum acceptable capture age and retention. Merely enabling an app
does not start exports or uploads. This design does not introduce a generic
backup executor or a generation retention registry.

Every precommit failure preserves the last successfully published export and
reports the new failure separately. A completed atomic publication remains
selected after late cancellation or unit failure, without rollback. Readers may
reuse that export only within
the consumer's explicit maximum capture age. Export identity and capture time
remain unchanged on retries and uploads; upload success never implies a new
application recovery point.

## Consequences

The capacity estimate is up to four export-sized trees per app: the published
export, capture staging and two simultaneous reader copies, plus existing
database-helper workspace and metadata overhead. Copy-on-write optimization may
reduce physical usage but correctness must allow ordinary independent copies.
Shared storage capacity and I/O remain shared failure domains. Reader preparation,
lock waits and job lifetimes must be bounded; unfinished copies are never usable.

Holding a shared lock throughout each upload uses less disk but lets a slow
destination delay fresh exports for healthy destinations. Immutable generations
with reader-aware reclamation would introduce additional lifetime bookkeeping.
Both alternatives were rejected in favor of bounded private copies.

The native lifecycle and validation mechanism are specified by
[ADR 0002](0002-native-export-lifecycle.md). Public options and commands are
documented in README.md and docs/recovery.md.
