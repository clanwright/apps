# Let native services own the export lifecycle

Status: historical decision, implemented for v0.4.0; disposable runtime acceptance
passed for that revision. Current verification and publication semantics follow
[ADR 0004](0004-source-and-predeployment-acceptance.md).

Apps uses NixOS systemd declarations and the existing capture commands for the
native export integration. `ExecStartPre` prepares private staging, `ExecStart`
runs the existing handler directly, `ExecStartPost` publishes a complete result,
and `ExecStopPost` cleans unfinished staging. Systemd supplies serialization,
state/runtime directories, deadlines, process teardown and failure reporting.
Small generated shell commands connect those stages and prepare reader copies;
there is no Python export engine, custom process supervisor or status ledger.

The standalone retained validator uses the existing bubblewrap isolation model
with a small shell wrapper for disposable input copying and bounded execution.
The input is a quiescent, administrator-controlled restored directory. It does
not promise safe privileged traversal of a filesystem being concurrently changed
by an attacker. Corrupt database contents still run only in the unprivileged
isolated validator. Bubblewrap supplies namespace isolation; a transient systemd
service supplies execution deadlines and process teardown. Validation therefore
requires a disposable Linux host with its local systemd system manager and the
same mount/cgroup namespaces over cgroup v2.
After successful systemd completion, the wrapper removes scratch only if the
service cgroup is absent or cgroup v2 reports no live processes or descendants.
Failed or uncertain runs retain the exact root-only directory for diagnosis and
manual removal after reboot. This avoids treating a pipe closing or a kill
timeout as proof that all descendants have exited. There is no custom lifetime
observer.

Atomic publication prevents readers from seeing partial or mixed captures.
It is not a promise of power-loss durability. Publication can succeed before a
later cleanup fails: retain the completed current export and report the service
failure without rolling it back or calling it a partial capture.

The independent reader copies and explicit capture-age policy in
[ADR 0001](0001-native-export-reader-isolation.md) remain unchanged. This decision
replaces the unpublished Python implementation and the working draft's custom
filesystem-durability and hostile concurrent-input machinery.

## Same-host validation follow-up

The disposable-host restriction above describes v0.4.0. For the supported
same-host path, [ADR 0003](0003-same-host-validation.md) supersedes the validator
lifecycle and failure-cleanup paragraphs. Export publication and reader lifetime
are unchanged.

The historical runtime results above are not acceptance of later source changes.
The current source/predeployment split supersedes the old VM gate policy.
