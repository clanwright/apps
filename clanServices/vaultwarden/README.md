# Vaultwarden role

`@clanwright/apps-vaultwarden` exposes the `app` role. It imports the public
Primitives PostgreSQL module with fixed database/user `vaultwarden`, state
`vaultwarden-db`, and local socket database access. Application state is
`vaultwarden-app` under `/var/lib/vaultwarden`. The native app unit requires and
orders after PostgreSQL; database restore metadata stops Vaultwarden.

The recipe uses Apps' exported Vaultwarden package. Registration is closed by
default. The admin environment-file secret defaults to `vaultwarden-admin-token`
and uses an existing root-only SOPS runtime path. Apps creates no secret value.

The native Caddy site has explicit public/private IPv4 listeners on port 443.
Public `/admin` responds 404; private admin routes are rate limited. Caddy replaces
`X-Real-IP` with the actual peer on every proxy path; Vaultwarden trusts the
loopback proxy. `vaultwarden-auth` uses the stock Fail2ban Vaultwarden filter and
native systemd journal backend. Its logging contract is part of the
[public API](../../README.md#public-interface).

Use the public selection API for ordinary composition. The lower-level role adds
`certificateEmail`, `ingress.publicIPv4`, `ingress.privateIPv4` and
`ingress.trustedInterfaces`. See the README for native Network claims,
certificate authority and the consumer's [Access/VPN composition](../../README.md#public-interface).
These integrations retain their native service owners.

See [dependencies and migration](../../README.md#dependencies-and-migration)
before changing database major versions, and [Recovery](../../docs/recovery.md)
for lifecycle retention, opt-in exports, historical validation and acceptance limits.
