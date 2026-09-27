# Vaultwarden role

`@clanwright/apps-vaultwarden` is an `app` role. It imports the public Primitives PostgreSQL module for the `vaultwarden` database and state, and retains application state under `/var/lib/vaultwarden`. It uses the exported Vaultwarden 1.37.3 package from the pinned Apps nixpkgs input. Registration is closed by default. The admin token is supplied through an existing root-only SOPS runtime path. The unit orders after and requires PostgreSQL; database restore metadata stops the Vaultwarden unit.

Enabled ingress uses explicit public and private IPv4 Caddy listeners on port 443. Public `/admin` responds 404; private admin paths are rate limited and proxied only on the private destination. The recipe contributes a Network v3.0.0 `privateIngressClaims` request for that destination and the selected trusted interfaces. Network owns the guard and its claim grants no port; the Vaultwarden recipe separately opens TCP 443 globally and on `tailscale0`. This role does not generate nftables rules. The authentication Fail2ban jail and log path retain their current identities. `disabled-retained` keeps app and database state and secret metadata without Vaultwarden runtime or ingress claims.

Use `clanModules.default` for normal selection; its high-level Vaultwarden option derives certificate, listener, and private guard settings from common installation context. The lower-level role interface is a recipe implementation surface. See the [public API](../../README.md).

Primitives v0.2.0 selects PostgreSQL 18.6. Existing PostgreSQL 17 installations require a separately tested major-version migration before activation; updating the recipe does not migrate data. See [dependency migration](../../README.md#dependency-migration).
