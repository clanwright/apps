# Recovery language and decisions

This index defines the recovery terms used by Apps. The [README](README.md)
owns the public configuration API; [Recovery](docs/recovery.md) owns operational
contracts and acceptance limits; [consumer locking](docs/nested-consumer-locking.md)
owns the release dependency gate.

| Term | Meaning |
| --- | --- |
| Application export | Complete application-owned capture after cleanup and restoration of prior service activity; capture alone does not establish semantic restore validity |
| Published export | Immutable complete export selected by atomic replacement of `current`; publication validity and attempt health are separate facts |
| Reader copy | Private independent local copy used for the complete lifetime of one backup job's readers |
| Capture age | Time since source capture, independent of upload or retry time; consumer policy chooses the admission limit |
| Semantic restore validation | Application-owned checks over separately restored data using compatible database tools; distinct from capture, upload and production restoration |

## Decisions

Accepted ADRs retain the rationale for the current contract:

- [ADR 0001: native export reader isolation](docs/adr/0001-native-export-reader-isolation.md)
- [ADR 0002: native export lifecycle](docs/adr/0002-native-export-lifecycle.md)
- [ADR 0003: same-host validation](docs/adr/0003-same-host-validation.md)
- [ADR 0004: source and predeployment acceptance](docs/adr/0004-source-and-predeployment-acceptance.md)

The [v1.0.0 release overview](CHANGELOG.md) describes current capabilities and contracts. Temporary evidence and work
plans remain under ignored `state/`, outside the public contract.
