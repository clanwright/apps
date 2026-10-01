# Bound semantic validation on an existing application host

Status: accepted and implemented for Apps issue #5 in v0.5.0; standalone
acceptance passed.

The dated acceptance below is historical. The VM fixtures were retired during
the 2026-09-30 refactor. Current source/build verification and mandatory,
unobserved native PREDEPLOY cases follow
[ADR 0004](0004-source-and-predeployment-acceptance.md); historical fixture
success does not certify a changed implementation.

The existing namespace sandbox already keeps the application validator away
from live state, service sockets, credentials and external networking. Its
v0.4.0 wrapper nevertheless requires a disposable host: preparation is outside
the managed service, resources and concurrent invocations are unbounded, and
failure cleanup is documented as requiring reboot.

Keep the public `bin/validate DIRECTORY` entrypoint and the existing application
handlers and stored formats. Move preparation and sandbox execution into one
native transient `apps-validate.service`. Use a host-wide admission lock and a
fixed unit name across both applications. Native systemd retains the slot until
the caller confirms teardown; there is no executor framework or scanning
cleanup daemon. The wrapper must not stop a pre-existing invocation.

Apply a whole-operation deadline, CPU/memory/swap/process bounds and reduced
I/O priority to preparation as well as database imports. Keep the existing
unprivileged bubblewrap boundary. Metadata remains provenance and never selects
the executable. Consumers retain the matching trusted closure separately.

Successful semantic validation authorizes scratch removal only after native
teardown is confirmed. Failure retains diagnostics; confirmed teardown permits
manual removal without reboot. Uncertain handoff or live descendants preserve
scratch and require operator recovery before another attempt; a retained native
unit blocks admission. No
validator action reboots or stops the application host.

Same-host support has a capacity boundary: administrators must reserve isolated
scratch capacity and enough RAM/CPU headroom for applications. Native resource
limits do not isolate kernel faults, storage latency or unkillable I/O. A
separate validation host remains necessary when those shared risks are
unacceptable. Apps does not provision a scratch filesystem, VM or provider.

Acceptance extends the existing isolation fixture for admission, resource and
failure paths, and the existing application VM fixture for continuous HTTP
probes, unchanged service identity and live data while both public validators
process actual restored copies. This proves semantic validation and fixture
continuity; production snapshot acceptance remains consumer-owned.

Acceptance passed on 2026-09-28: the ARM Linux isolation VM covered effective
resource limits, shared admission, caller death, foreign-unit ownership and
conservative teardown. The existing full x86 Linux application VM on an ARM
driver under QEMU TCG validated all four restored copies while checking HTTP
availability, unchanged service identities and live fixture data. Each also
rejected an incompatible format without changing those live fixtures. This is
full-VM evidence, not native x86 hardware or production-snapshot acceptance.

See [the public contract](../recovery.md#validation-on-an-existing-application-host)
for exact limits and operational prerequisites. The native mechanism follows
systemd 261.2 [resource controls](https://github.com/systemd/systemd/blob/v261.2/man/systemd.resource-control.xml),
[service lifecycle](https://github.com/systemd/systemd/blob/v261.2/man/systemd.service.xml)
and [process teardown](https://github.com/systemd/systemd/blob/v261.2/man/systemd.kill.xml).
