> **Archived.** This module now lives in the Clanwright monorepository as
> `bricks/apps` (https://github.com/ibelyasov/clanwright) and is no longer
> developed or released here.

# Clanwright Apps

Declarative Clan recipes for Obsidian LiveSync and Vaultwarden. The public `clanModules.default` module selects apps by machine and contributes ordinary Clan inventory instances. The recipes use the public Primitives database/recovery SDK and Network native NixOS interfaces for certificates, Caddy, firewall, and private ingress protection. They do not provision DNS, ACME provider credentials, SOPS values, or Tailscale enrollment.

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

`obsidian` and `vaultwarden` are independently nullable and default to `null`. Each selected app defaults to `lifecycle = "enabled"`; `lifecycle = "disabled-retained"` keeps declared state and secret metadata while removing runtime and ingress requests. Setting an app back to `null` withdraws its declarations and does not itself prune or restore data. A retained-only machine needs no `installation` context. An active Obsidian selection needs public IPv4 and certificate email; it does not need private ingress. Active Vaultwarden also requires private ingress with a distinct destination IPv4. Both listeners use port 443 with one hostname; public `/admin` responds 404, while private admin routes bind only the declared private IPv4. The recipes open TCP 443 globally; they do not force an interface-specific port rule. Network guards the private destination for the declared interfaces, with loopback implicitly trusted; its private ingress claim grants no port. Private ingress is a generic IPv4/interface contract; the example uses `tailscale0`, but Apps neither enrolls a device nor supplies a Tailscale readiness mechanism.

Both apps accept `domain`, optional `certificateId` (default `null`, using the canonical app domain), `lifecycle`, and `export.enable` (default false). Supply an existing physical certificate ID explicitly to preserve its identity when upgrading. Obsidian additionally accepts `adminConfigSecretName` (default `obsidian-admin-ini`). Vaultwarden accepts `adminTokenSecretName` (default `vaultwarden-admin-token`), `registration.open` (default false), `fail2ban.ignoreIPs` (default empty), and `logLevel` (default `warn`; allowed values are `trace`, `debug`, `info`, `warn`, `error`). Error logging cannot be disabled because authentication Fail2ban depends on it. Secret names refer to existing SOPS bindings; this module creates or reads no secret value. Vaultwarden's database and user are fixed as `vaultwarden`; backend ports and package selection are recipe owned.

The app instances are `<machine>--app-obsidian` and `<machine>--app-vaultwarden`, with public service names `@clanwright/apps-obsidian` (`server`) and `@clanwright/apps-vaultwarden` (`app`). Active selections request shared `<machine>--network-certificates`, `<machine>--network-caddy`, and `<machine>--network-firewall` instances. Apps contributes their role membership without shared profile settings. The consumer owns those settings and binds the public `apps` and `network` inputs. The exported `packages.x86_64-linux.vaultwarden` is the package used by the recipe; no other platform package export is promised.

Recipes declare `services.caddy.virtualHosts.<domain>` with explicit listener addresses, `useACMEHost`, and app routes; `security.acme.certs.<certificateId>` with domain, per-certificate email and ACME group; and Vaultwarden's `networking.firewall.privateIngress.<instanceName>`. Network owns the private guard. Its claim grants no port. Certificate challenges default to `null`: the consumer must supply the appropriate per-certificate challenge configuration through Network's public interface. The consuming host's native ACME module and stock host Lego own issuance and migration. Apps does not override the host ACME package or require per-app Caddy access logs.

Vaultwarden uses the stock Fail2ban Vaultwarden filter with a native systemd journal backend and `vaultwarden-auth` jail. Caddy overwrites `X-Real-IP` with the actual peer address on every proxy path; Vaultwarden trusts this header only from its loopback proxy. Apps adds no `tailscaled` readiness dependency. When private-address readiness is required, the consumer attaches `access.lib.tailscaleReadyGate { pkgs; ipv4; interface; }` to ordinary native Caddy `ExecStartPre`, using the selected private listener IPv4 and effective `services.tailscale.interfaceName`. Effective `services.tailscale.package` must be Access's exported package; caller `pkgs` supplies support tools. There is no privileged prefix, sandbox relaxation, per-reload gate or watcher. Verify the native consumer behavior against the [recovery acceptance boundary](docs/recovery.md#acceptance-boundary).

When a consumer shares a public listener with VPN's native CONNECT proxy, it explicitly prepends the same complete exported policy to each app's existing named site that can match a CONNECT target authority:

```nix
services.caddy.virtualHosts."obsidian.example.invalid".extraConfig =
  lib.mkBefore config.clanwright.vpn.naiveproxy.connectRoute;
```

Do the same for the selected Vaultwarden hostname on that listener. Keep the existing owner, aliases, listener addresses and certificate; do not repeat the catch-all attachment or set `forwardProxy` on an ordinary app site. The full fragment retains its CONNECT and actual public-bind443 guard, authentication and ACL, including exclusion of private binds. Named terminal Host routes can shadow the catch-all even when its inner policy is first; matching canonical and alias target authorities need the affected native composition controls. Apps does not enumerate or attach other consumers' sites.

The lower-level Clan roles expose `certificateEmail` and `ingress.publicIPv4`; Vaultwarden additionally exposes `ingress.privateIPv4` and `ingress.trustedInterfaces`. Normal selection uses `installation.privateIngress.destinationIPv4` and `trustedInterfaces`; the composition module maps these to the role settings. State, secret names, service identities and routes remain stable. Apps performs no automatic state, secret or database migration. Required operator migrations are documented in [recovery compatibility](docs/recovery.md#lifecycle-historical-backups-and-migration).

## Dependencies and migration

`flake.nix` declares immutable producer revisions; `flake.lock` records the resolved
graph. Apps uses these authorities without overriding their internal follows:

| Input | Responsibility |
| --- | --- |
| `clan-core` | Clan inventory/module composition and its caller Nixpkgs glue |
| `apps-nixpkgs` | Vaultwarden package (1.37.3), also exported as `packages.x86_64-linux.vaultwarden` |
| `primitives` | Native PostgreSQL/CouchDB modules and package-valued recovery SDK; effective database packages supply their own executables/configuration, with explicit same-Primitives Erlang for the default CouchDB component cohort |
| `network` | Specialized Caddy package, native certificate/firewall composition and private ingress guard |

The consuming host's native ACME module and stock Lego remain the issuance
and migration authority. Apps does not unify these package cohorts. Access startup readiness and VPN
CONNECT policy are optional consumer integrations. See
[recovery package authority](docs/recovery.md#public-boundary) for supported
database components and overrides. Releases must pin compatible published
Primitives and Network interfaces and pass the normal published-input gates
below; temporary input overrides do not establish a shipped dependency graph.

Existing PostgreSQL 17 installations require a separately planned and tested
major-version migration using `pg_upgrade` or logical dump/restore. Do not start
PostgreSQL 18 against a PostgreSQL 17 directory. Keep the previous pinned
configuration and compatible validator closures until the migrated application
and backups are accepted. Updating Apps performs no migration. Consult the
Primitives migration contract at the revision you adopt and
[recovery compatibility](docs/recovery.md#lifecycle-historical-backups-and-migration).
The [v1.0.0 release overview](CHANGELOG.md) describes the supported capabilities and their purpose.

## Application recovery

Opt in independently on each selected app, keeping its domain and installation
settings:

```nix
clanwright.apps.machines.server = {
  obsidian.export.enable = true;
  vaultwarden.export.enable = true;
};
```

An active opted-in recipe provides an unscheduled native capture service and
`config.system.build.appsVaultwardenExport` or `appsLiveSyncExport`. Their public
commands prepare an independent reader with an explicit capture-age limit and
validate separately restored data using a retained matching closure. The
consumer, such as [Clanwright Reliability](https://github.com/clanwright/reliability),
owns native Restic jobs, reader lifetime, scheduling, destinations and retention.
Apps has no Restic/provider dependency or generic backup-job constructor.

[Recovery](docs/recovery.md) is the canonical contract for service names, paths,
atomic publication, failure handling, age, privileges, resource/storage budgets,
semantic validation and historical compatibility. Consult it before integrating
backup jobs or invoking validation on an existing application host.

## Verification and release acceptance

Apps declares host state and recovery commands. Evaluation and tests do not
activate machines, mutate providers/DNS, create secret values or initiate backup
operations. Release acceptance requires independent review, standalone composition,
the applicable native check builds, and fresh consumer locking against the final
published dependency graph. Retain readable output, input/source identities and
durations under ignored `state/`.

| Ordinary check output | Evidence |
| --- | --- |
| `checks.x86_64-linux.contract` | Standalone Clan lifecycle, package authority, database declarations and shared Network composition |
| `checks.x86_64-linux.http-runtime` | Local Caddy/backend route and proxy-header fixture |
| `checks.x86_64-linux.recovery-runtime` | Disposable capture/import and semantic validation |
| `checks.aarch64-linux.recovery-runtime` | Native architecture variant of the same recovery fixture |
| `checks.aarch64-linux.export-tools` | Reader, retained-validator and native export stage builds |

The focused LiveSync callback regression uses Bash, jq, awk and sed, with no
CouchDB process or VM. It runs the actual callback across three pages, escaped
cursors, payload reduction, conflicting revisions and malformed-response cases:

```sh
bash checks/recovery/livesync-pagination.sh state/livesync-pagination
```

Run recovery-runtime on a builder's native supported architecture. Emulated or
unavailable execution is not native runtime PASS. The checks' exact scope and
one canonical **PREDEPLOY / NOT OBSERVED** boundary are in
[recovery acceptance](docs/recovery.md#acceptance-boundary). Release publication
and ordinary process checks do not close those runtime criteria.

Run the consumer gate against the exact immutable Apps release candidate, with
its compatible published producer pins:

```sh
bash checks/consumer-lock.sh github:clanwright/apps/REVISION
```

It covers Apps-only and coordinated fresh locking, a representative coordinated
upgrade, native resolved-source convergence, contract evaluation and identical
relocking. Its optional second argument selects an immutable public baseline;
see [consumer locking](docs/nested-consumer-locking.md). A standalone check does
not waive a failing consumer gate or establish arbitrary consumer compatibility.

## Documentation

- [Recovery](docs/recovery.md): native exports, readers, retained validation and acceptance limits.
- [Consumer locking](docs/nested-consumer-locking.md): release dependency gate and evidence.
- [Obsidian role](clanServices/obsidian/README.md) and [Vaultwarden role](clanServices/vaultwarden/README.md): recipe state, database and route details.
- [Recovery language and decisions](CONTEXT.md): glossary and immutable ADR index.
- [v1.0.0 release overview](CHANGELOG.md): current capabilities, contracts and rationale.
