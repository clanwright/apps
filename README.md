# Clanwright Apps

Declarative Clan recipes for Obsidian LiveSync and Vaultwarden. The public `clanModules.default` module selects apps by machine and contributes ordinary Clan inventory instances. The recipes use [Primitives v0.2.0](https://github.com/clanwright/primitives/releases/tag/v0.2.0) for CouchDB and PostgreSQL, and [Network v3.0.0](https://github.com/clanwright/network/releases/tag/v3.0.0) for certificates, Caddy, firewall, and private ingress protection. They do not provision DNS, ACME provider credentials, SOPS values, or Tailscale enrollment.

## Public interface

Import `inputs.apps.clanModules.default` once into the Clan configuration. Bind the inputs as `apps` and `network` in `self.inputs` for native inventory resolution. Select apps under `clanwright.apps.machines.<machine>`:

```nix
clanwright.apps.machines.server = {
  installation = {
    publicIPv4 = "192.0.2.10";
    certificateEmail = "operator@example.invalid";
    privateIngress = {
      destinationIPv4 = "100.64.0.10";
      trustedInterfaces = [ "tailscale0" ];
    };
  };
  obsidian = { domain = "obsidian.example.invalid"; };
  vaultwarden = { domain = "vaultwarden.example.invalid"; };
};
```

`obsidian` and `vaultwarden` are independently nullable and default to `null`. Each selected app defaults to `lifecycle = "enabled"`; `lifecycle = "disabled-retained"` keeps declared state and secret metadata while removing runtime and ingress requests. Setting an app back to `null` withdraws its declarations and does not itself prune or restore data. A retained-only machine needs no `installation` context. An active Obsidian selection needs public IPv4 and certificate email; it does not need private ingress. Active Vaultwarden also requires private ingress with a distinct destination IPv4. Both listeners use port 443 with one hostname; public `/admin` responds 404, while private admin routes bind only the declared private IPv4. The Vaultwarden recipe opens TCP 443 globally and on `tailscale0`. Network guards the private destination for the declared interfaces, with loopback implicitly trusted; its private ingress claim grants no port. This contract does not enroll a device in Tailscale.

Obsidian accepts `domain`, optional `adminConfigSecretName` (default `obsidian-admin-ini`), and `lifecycle`. Vaultwarden accepts `domain`, optional `adminTokenSecretName` (default `vaultwarden-admin-token`), `lifecycle`, `registration.open` (default false), `fail2ban.ignoreIPs` (default empty), and `logLevel` (default `warn`). Secret names refer to existing SOPS bindings; no value is created or read by this module. Database names, users, backend ports, package versions, ACME certificate names, and Network instances are recipe owned.

The app instances are `<machine>--app-obsidian` and `<machine>--app-vaultwarden`, with public service names `@clanwright/apps-obsidian` (`server`) and `@clanwright/apps-vaultwarden` (`app`). Active selections request the shared instances `<machine>--network-certificates`, `<machine>--network-caddy`, and `<machine>--network-firewall`. The same IDs are intended to compose with a consumer's existing core profile. The exported `packages.x86_64-linux.vaultwarden` is the package used by the Vaultwarden recipe; no other platform package export is promised.

This is a breaking Obsidian recipe rename from v0.1.0. Before updating a consumer, change any direct service reference from `@clanwright/apps-livesync-couchdb` to `@clanwright/apps-obsidian` and its inventory instance from `<machine>--app-livesync-couchdb` to `<machine>--app-obsidian`; keep the `server` role. The CouchDB state declaration changes from `livesync-couchdb` to `obsidian`, but its data directory remains `/var/lib/couchdb`. Update any backup or recovery configuration that names the old state declaration, and verify it still covers that directory. The default SOPS secret name changes from `livesync-couchdb-admin-ini` to `obsidian-admin-ini`: provide the existing administrator INI content under the new name before enabling the new recipe, or explicitly set `adminConfigSecretName` to an already provisioned name. The Caddy access log moves from `/var/log/caddy/livesync-couchdb-access.log` to `/var/log/caddy/obsidian-access.log`; historical logs stay at the old path. This module does not migrate state or secret values.

The lock pins Clan `c612dac4b2bfb5278b7c366f250044ddb5401bcb`, Primitives `9dd13dd84479914fe8465ff6f77d2bb1f8034e2e`, Network `bfba5e74c3ee09ab92534fc2e7fdf31dc4525bb2`, and Apps nixpkgs `8d5d270900d3fc75655ea2d9d248b234f6631439`. External inputs retain their own dependency locks; Apps does not override their follows. Apps nixpkgs supplies Vaultwarden 1.37.3. Primitives v0.2.0 supplies CouchDB 3.5.2 and PostgreSQL 18.6. Network owns its Caddy package, and the standalone check tools come from Clan's nixpkgs. Shared Caddy and Firewall instances declare role membership while their settings remain with the consumer's core profile. Apps supplies a default certificate email; a conflicting effective email fails a machine assertion. The app recipes independently contribute their HTTPS port and route claims through native NixOS and Network options.

## Dependency migration

Adopting these dependencies is a breaking upgrade for existing consumers:

- Primitives v0.2.0 selects PostgreSQL 18 instead of 17. Before activating an existing Vaultwarden installation, plan and test a major-version migration with `pg_upgrade` or a logical dump/restore. Preserve the old pinned configuration and compatible recovery tooling until the migrated application and historical backups are accepted. Do not start PostgreSQL 18 against a PostgreSQL 17 data directory. Updating Apps does not perform this migration. See the [Primitives migration contract](https://github.com/clanwright/primitives/blob/v0.2.0/README.md#postgresql-major-version-migration).
- Network v3.0.0 selects Lego 5. The consuming host's native NixOS ACME module must support Lego 5 commands and Lego 4 account migration; changing only the Network or Apps pin is insufficient. Network verifies compatibility for every certificate on the host, including native certificates outside Apps. Network's verified nixpkgs baseline is `8d5d270900d3fc75655ea2d9d248b234f6631439`. See the [Network adoption contract](https://github.com/clanwright/network/blob/v3.0.0/docs/operations/release.md#consumer-adoption).

Service names, routes, state declarations and secret names are unchanged by this dependency refresh.

## Application recovery

Enabled recipes publish `clanwright.recovery.units.vaultwarden` and
`clanwright.recovery.units.livesync` through the
[Primitives v0.2.0 recovery contract](https://github.com/clanwright/primitives/blob/v0.2.0/docs/recovery.md).
The `livesync` recovery ID is stable even though the recipe and native state are
named `obsidian`. Both units use `contractVersion = 1`. Vaultwarden groups native
`vaultwarden-app` and `<database-name>-db` state; LiveSync refers to `obsidian`.
Native Clan state remains the only folder registry.

An executor selects these IDs and invokes the declared commands; consumers do
not repeat application paths, database commands or semantic checks. Declaring
the units does not enable transmission, schedules, destinations or retention.
Apps has no dependency on Reliability or a backup provider.

`disabled-retained` withdraws recovery units and runtime/network claims while
preserving state and secret metadata. A `null` selection withdraws declarations.
Neither transition deletes local data or historical backups. Executors must
reject a selected missing unit. Before changing a pin or disabling/removing an
app, retain its pinned configuration and validator closures in a separate
recovery environment; the current host configuration is not an archive of old
handlers. Keep the matching database and application versions with those
closures. Restoring old data is not a reason to re-enable production services.

The command and artifact compatibility details are in [Recovery](docs/recovery.md).

## Limits and verification

The module declares host state and recovery commands. It does not activate machines, change providers or DNS, create secret values, or initiate backup operations. The standalone contract check evaluates isolated Clan compositions, including compatible core profile settings, lifecycle, package authority, private guard, and route behavior. It checks Vaultwarden's PostgreSQL declaration, local socket URL, backend selection, systemd dependencies and recovery-unit declarations. Primitives owns database service readiness mechanics; evaluation does not start Vaultwarden or prove its database connection. The HTTP fixture runs a local Caddy/backend simulation without a real database. The recovery runtime fixture exercises disposable database capture/import and semantic checks, failure cleanup and validation isolation. These checks do not prove production DNS, certificates, firewall packet behavior, live application traffic, or the consuming executor's privileged handoff. Consumer adoption and deployment require their own acceptance checks.

### Release acceptance

Release acceptance requires both standalone checks and fresh nested-consumer locking against the same published revision. With Nix, Bash, and Python 3 available, run from this checkout:

```sh
mkdir -p state
nix build --no-link \
  github:clanwright/apps/REVISION#checks.x86_64-linux.contract \
  github:clanwright/apps/REVISION#checks.x86_64-linux.http-runtime \
  github:clanwright/apps/REVISION#checks.aarch64-linux.recovery-runtime \
  > state/release-standalone.log 2>&1
bash checks/consumer-lock.sh github:clanwright/apps/REVISION
```

Replace the reference in both commands with the exact candidate revision being accepted. Composition and HTTP builds need an `x86_64-linux` builder. Run the complete recovery suite on a native supported Linux builder: the example uses ARM; substitute `checks.x86_64-linux.recovery-runtime` when using native x86. The x86-emulated runtime check is not a release gate. See the [runtime acceptance boundary](docs/recovery.md#acceptance-boundary), including the current x86-emulation limitation. The consumer gate only evaluates; it must start without a consumer lock, generate one normally, preserve the published dependency source identities and relative source anchors, evaluate the Apps contract, and rerun locking without byte changes. Its isolated fixtures and readable logs are retained under ignored `state/`. A successful standalone check does not waive a failing consumer gate.

On Nix `2.34.7+1` and the official stable `2.35.2`, Apps `v0.1.0` fails the fresh consumer gate while resolving `apps/network/data-mesher`: Nix looks for its relative path in the Apps source tree. Existing valid consumer locks are a different acceptance case. See [the diagnosis and upstream handoff](docs/nested-consumer-locking.md); do not repair this by copying Network stubs or adding consumer overrides.
