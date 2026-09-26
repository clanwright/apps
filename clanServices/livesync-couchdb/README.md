# Obsidian LiveSync role

`@clanwright/apps-livesync-couchdb` is a `server` role. It imports the public Primitives CouchDB module, declares the existing CouchDB state and admin INI secret metadata, and sets LiveSync-specific CORS and authentication settings. CouchDB binds loopback. When enabled, the recipe contributes a public IPv4 Caddy fragment and certificate claim; only `/`, `/_session`, `/obsidian`, and `/obsidian/*` proxy to CouchDB. Other paths return 404. `disabled-retained` retains state and secret metadata without CouchDB runtime or ingress claims.

Use `clanModules.default` for normal selection; its high-level Obsidian option derives certificate and listener settings from common installation context. The lower-level role interface is a recipe implementation surface. See the [public API](../../README.md).
