# Changelog

## Unreleased

## v0.6.1 — 2026-09-30

- Adopt Network v4.1.0 (`a216e7b311c2f2e36fa0e0ee137c867acb04a54e`). It adds destination-scoped public firewall ports (`public.destinations`) to `@clanwright/network-firewall`; the change is additive and Apps recipes keep their host-wide HTTPS port and route claims.
- Only the `network` lock node changes. Clan, Primitives, Apps nixpkgs, service names, routes, state declarations and secret names are unchanged. The Network v4.0.0 static WAN migration still applies to consumers upgrading from earlier releases.

## v0.6.0 — 2026-09-29

- Adopt Network v4.0.0 (`2981962f1f590fae66c05c50a3d793825281de9e`). Its only change is the static WAN address model; Apps recipes do not use static WAN and their Network claims are unchanged.
- Breaking for consumers that use `@clanwright/network-wan-static` with the coordinated Network pin: migrate `secondaryIPv4`, `routeTableName`, `routeTableId` and `rulePriority` to `additionalIPv4s` before adoption.
- Clan, Primitives, Apps nixpkgs and every other locked source are unchanged, as are service names, routes, state declarations and secret names.

## v0.4.0 — 2026-09-27

- Add opt-in native application export services and independent reader copies for native Restic jobs, with complete-only publication, capture-age admission and last-good retry semantics.
- Ship isolated semantic restore-validation entry points with private restored-file handoff and separately retainable validator closures.
- Preserve existing application capture formats and command contracts; consumer-owned destinations, credentials, schedules and retention remain outside Apps.
- Use native systemd stages for capture, publication and cleanup, and the existing bubblewrap model for disposable validation. No Python runtime engine, generic backup executor or destination abstraction is introduced.
- Add actual native-service, two-destination Restic and validator-isolation fixtures. Export settings default off and add no automatic timers or uploads.

## v0.3.1 — 2026-09-27

- Adopt Network v3.0.1 (`efeaa948d58e678d27a5a812f0293a3ada71c681`) to fix ordinary fresh nested-consumer locking and dependency updates on released Nix versions.
- Extend consumer acceptance to coordinated Apps/Network/Primitives updates, exact source convergence and byte-identical relocking.
- Preserve application recipes, state, secret metadata, routes, recovery contracts and all other accepted dependency sources. Earlier PostgreSQL and ACME migration requirements still apply.

## v0.3.0 — 2026-09-27

- Publish application-owned `vaultwarden` and `livesync` recovery units through Primitives v0.2.0's public contract, without enabling a backup executor or provider.
- Capture Vaultwarden's native PostgreSQL export and application files together; capture LiveSync through the public CouchDB helper while writes are paused. Preserve prior service activity and reject incomplete captures.
- Add isolated database import and semantic validation for attachment/file and document/chunk relationships, with explicit stored formats and historical-handler retention guidance.
- Extend standalone lifecycle/composition checks and add disposable recovery runtime checks, including failure cleanup and validator isolation. Native ARM runtime acceptance passes; x86 emulation is not a release gate.

- Update Clan to `c612dac4b2bfb5278b7c366f250044ddb5401bcb`, Apps nixpkgs to `8d5d270900d3fc75655ea2d9d248b234f6631439`, Network to v3.0.0, and Primitives to v0.2.0. Vaultwarden advances to 1.37.3.
- Breaking: adopt CouchDB 3.5.2 and PostgreSQL 18.6 from Primitives. Existing PostgreSQL 17 consumers must separately plan and test a major-version migration before activation.
- Breaking: Network now supplies Lego 5 and requires a compatible native NixOS ACME module with v4 account migration support.
- Preserve released external dependency locks; state declarations, secret metadata, service identities, and routes are unchanged.
- Reconfirm the existing fresh nested-consumer locking failure on Nix 2.35.2 for the dependency refresh; Apps #1 remains unresolved.

## v0.2.1 — 2026-09-27

- Cover Vaultwarden's required PostgreSQL dependency, database backend and local socket URL, public database declaration, and retained lifecycle withdrawal in the standalone contract.
- Clarify that Apps checks recipe composition while Primitives owns database readiness mechanics; the HTTP fixture does not run a real database.
- Keep recipes and dependency pins unchanged. The known fresh nested-consumer locking limitation in Apps #1 remains.

## v0.2.0 — 2026-09-26

- Breaking: rename the Obsidian service to `@clanwright/apps-obsidian`, its instance to `<machine>--app-obsidian`, its CouchDB state declaration to `obsidian`, its default admin INI secret to `obsidian-admin-ini`, and its Caddy access log to `obsidian-access.log`. Consumers must update direct references and prepare the new secret binding before adoption; see the README migration note.
- Add a fresh nested-consumer release gate and a synthetic relative-input reproduction for Apps #1.
- Document the Nix `2.34.7+1` and `2.35.2` consumer-locking blocker and upstream handoff; release dependency pins remain unchanged.

## v0.1.0 — 2026-09-26

- Extract Obsidian LiveSync and Vaultwarden recipes from the Clanwright consumer.
- Add native per-machine application selection and shared Network requests.
- Add Vaultwarden private ingress claims through Network v2.2.0.
