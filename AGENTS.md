# Clanwright Apps

This standalone repository owns the Obsidian LiveSync and Vaultwarden application recipes and their native Clan composition module. `README.md` is the public API reference. The released Primitives and Network inputs own their respective database and network mechanisms. Use only their public interfaces; do not copy or inspect their implementations while working here.

Preserve state, secret metadata, routes, and service identities when changing recipes. Never print or persist secret values, private keys, passwords, or live client profile URLs. Evaluation and tests must not deploy, mutate providers/DNS, restore or prune backups, or change credentials. Pin accepted external versions before release; no local path inputs or consumer reverse dependencies may appear in release sources.

A null app selection withdraws its declarations. `disabled-retained` keeps state and secret metadata while removing runtime/network claims. Validate both lifecycles and shared Network composition in the standalone Clan fixture. Keep readable check output in a local ignored state directory.
