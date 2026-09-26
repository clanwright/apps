# Clanwright Apps

Declarative Clan recipes for Obsidian LiveSync and Vaultwarden. The public `clanModules.default` module selects apps by machine and contributes ordinary Clan inventory instances. The recipes use [Primitives v0.1.0](https://github.com/clanwright/primitives/releases/tag/v0.1.0) for CouchDB and PostgreSQL, and [Network v2.2.0](https://github.com/clanwright/network/releases/tag/v2.2.0) for certificates, Caddy, firewall, and private ingress protection. They do not provision DNS, ACME provider credentials, SOPS values, or Tailscale enrollment.

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

The lock pins Clan `3b5832a13fb0ad1e57c2dafd246ca8ab60ad1b20`, Primitives `6979fee86075ae62492e1572be434caf84c8337b`, Network `7cbc2a01e9e18299b2ac606714081cc57470778d`, and Apps nixpkgs `c27cdad491a991b11ed731760aa2ef8db0cb0410`. External inputs retain their own dependency locks; Apps does not override their follows. Shared Caddy and Firewall instances declare role membership while their settings remain with the consumer's core profile. Apps supplies a default certificate email; a conflicting effective email fails a machine assertion. The app recipes independently contribute their HTTPS port and route claims through native NixOS and Network options.

## Limits and verification

The module declares host state only. It does not activate machines, change providers or DNS, create secret values, or perform backup operations. Standalone checks evaluate isolated Clan compositions, including compatible core profile settings, lifecycle, package authority, private guard, and route behavior. The HTTP fixture runs a local Caddy/backend simulation; it does not prove production DNS, certificates, firewall packet behavior, or live application traffic. Consumer adoption and deployment require their own acceptance checks.

### Release acceptance

Release acceptance requires both standalone checks and fresh nested-consumer locking against the same published revision. With Nix, Bash, and Python 3 available, run from this checkout:

```sh
mkdir -p state
nix flake check --all-systems --no-update-lock-file github:clanwright/apps/v0.1.0 > state/release-standalone.log 2>&1
bash checks/consumer-lock.sh github:clanwright/apps/v0.1.0
```

Replace the reference in both commands with the exact candidate revision being accepted. Standalone builds need an `x86_64-linux` builder. The consumer gate only evaluates; it must start without a consumer lock, generate one normally, preserve the published dependency source identities and relative source anchors, evaluate the Apps contract, and rerun locking without byte changes. Its isolated fixtures and readable logs are retained under ignored `state/`. A successful standalone check does not waive a failing consumer gate.

On Nix `2.34.7+1` and the official stable `2.35.2`, Apps `v0.1.0` fails the fresh consumer gate while resolving `apps/network/data-mesher`: Nix looks for its relative path in the Apps source tree. Existing valid consumer locks are a different acceptance case. See [the diagnosis and upstream handoff](docs/nested-consumer-locking.md); do not repair this by copying Network stubs or adding consumer overrides.
