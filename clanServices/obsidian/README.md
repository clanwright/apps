# Obsidian LiveSync role

`@clanwright/apps-obsidian` exposes the `server` role and imports the public
Primitives CouchDB module. It supplies LiveSync CORS/authentication settings;
CouchDB binds loopback. The native Caddy route proxies only `/`, `/_session`,
`/obsidian` and `/obsidian/*`; other paths return 404.

The inventory instance is `<machine>--app-obsidian`. State `obsidian` remains
under `/var/lib/couchdb`, with administrator INI secret metadata named
`obsidian-admin-ini` by default. The recovery ID is `livesync`, preserving its
identity independently of the state declaration name.

Use [the public selection API](../../README.md#public-interface) for installation,
certificate and lifecycle settings. The lower-level role adds `certificateEmail`
and `ingress.publicIPv4`. Network and the host own certificate challenges and
issuance; Apps creates no credentials. See [Recovery](../../docs/recovery.md)
for opt-in exports, retained validation and acceptance limits, and the
[changelog](../../CHANGELOG.md) for shipped changes.
