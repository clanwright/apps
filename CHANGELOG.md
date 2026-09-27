# Changelog

## Unreleased

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
