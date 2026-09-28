# Clanwright Apps

Apps owns the application recipes and consistent recovery artifacts for
Vaultwarden and Obsidian LiveSync. Native database and network mechanisms remain
with Primitives and Network; backup destinations and policy belong to consumers.

## Recovery language

**Application export**:
A complete application-owned capture whose cleanup and restoration of the prior
service activity have succeeded. Capture completion alone does not establish
semantic restore validity.

**Published export**:
The last successfully completed export made available for readers. A failed new
capture does not replace it or change its identity or capture time.

**Reader copy**:
A private, independent local copy of a published export used by one backup job.
Its lifetime covers the complete reader process lifetime; network operations do
not hold the publication lock.

**Capture age**:
Elapsed time since the source capture, independent of upload or retry time. The
consumer chooses the maximum acceptable age for admitting a reader copy.

**Semantic restore validation**:
Application-owned checks over disposable restored data using compatible database
tools. It is distinct from successful capture, upload and production restoration.

The reader-copy integration is implemented for v0.4.0 and verified with disposable
runtime checks; see
[ADR 0001](docs/adr/0001-native-export-reader-isolation.md) and
[ADR 0002](docs/adr/0002-native-export-lifecycle.md). The currently shipped
command interface is documented in [Recovery](docs/recovery.md).

Same-host semantic validation is implemented and verified for issue #5 in v0.5.0.
A bounded native systemd service owns preparation and validation,
with one invocation admitted across both apps. Confirmed teardown permits
cleanup without reboot; uncertainty preserves scratch for operator recovery.
The host must reserve scratch capacity and application headroom. See
[ADR 0003](docs/adr/0003-same-host-validation.md) for the decision and acceptance
boundary, and [Recovery](docs/recovery.md) for the supported invocation.
