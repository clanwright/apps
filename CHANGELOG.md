# Apps v1.0.0

Apps provides declarative Clan recipes for Obsidian LiveSync and Vaultwarden,
with application-owned exports and retained semantic recovery validation.

- Native per-machine selection composes shared Network services. `null` withdraws
  declarations; `disabled-retained` preserves state and secret metadata while
  withdrawing runtime and ingress. Existing service identities and explicit
  certificate IDs keep application state separate from activation policy.
- Native Caddy sites, host ACME certificates and Network private ingress protect
  the public application/private administration boundary. Consumers select
  per-certificate challenges; the host owns issuance. Vaultwarden uses the stock
  journal Fail2ban filter and Caddy's actual peer address for authentication logs.
- Opt-in foreground systemd capture publishes complete immutable exports through
  an atomic commit. Precommit failures preserve the previous export; completed
  commits survive late cancellation. Independent readers enforce original
  capture age and release publication locks before network delivery, so slow
  destinations do not hold capture hostage.
- Retained validators import separately restored databases and check Vaultwarden
  attachment/file and LiveSync document/chunk relationships. Native admission,
  resource limits and isolated scratch support validation on a suitably provisioned
  application host. Effective database packages and explicit CouchDB Erlang retain
  their component authority; backup metadata never chooses executables.
- Consumers own backup destinations, credentials, schedules, reader lifetime and
  retention. Standalone composition, native database/HTTP fixtures, focused
  pagination regression and fresh/coordinated public consumer locking cover the
  source and release contracts. Actual native manager, same-host and network
  observations follow the [recovery acceptance boundary](docs/recovery.md#acceptance-boundary).

Use the [public API](README.md), [recovery contract](docs/recovery.md) and
[consumer locking gate](docs/nested-consumer-locking.md). Necessary operator
migration and retained-validator requirements live in
[recovery compatibility](docs/recovery.md#lifecycle-historical-backups-and-migration);
accepted rationale remains in the [ADR index](CONTEXT.md#decisions).
