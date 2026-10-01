# Nested consumer locking

The Apps release gate tests normal fresh locking and one representative upgrade against an exact Apps revision. Run it from this checkout with Nix, Bash and jq:

```sh
bash checks/consumer-lock.sh github:clanwright/apps/REVISION
```

The optional second argument is an immutable public Apps baseline reference. The default is Apps v0.5.1, revision `4f8acab8d06dfc78961b518001417bb0c30388ea`. Choose a prior accepted revision when the default would not exercise a source upgrade. This argument is not an existing consumer directory or lockfile.

## Current acceptance

The script creates three small, project-owned fixtures under ignored `state/consumer-lock/`:

- An Apps-only consumer starts without a lockfile and runs ordinary `nix flake lock`.
- A coordinated consumer starts without a lockfile and pins direct Network and Primitives to the candidate's resolved revisions. Their complete resolved source trees must match the Apps-owned inputs.
- A representative consumer first locks the public baseline and its direct Network/Primitives revisions, plus a tiny independent local sentinel input. The script changes its own declarations to the candidate revisions and runs ordinary `nix flake update apps network primitives`. The sentinel's actual source must remain unchanged.

Every candidate consumer's resolved Apps source projection must equal the candidate's projection. It includes a root header and sorted set of reachable source headers: actual effective path, available content hash and revision, flake/non-flake distinction and named immediate input-to-path bindings. Each direct input is projected in the same way. The script uses [`builtins.getFlake`](https://nix.dev/manual/nix/2.34/language/builtins.html#builtins-getFlake) and [`builtins.genericClosure`](https://nix.dev/manual/nix/2.34/language/builtins.html#builtins-genericClosure) in [`checks/consumer/source-tree.nix`](../checks/consumer/source-tree.nix). Nix resolves `follows` and relative or subdirectory source paths; Apps does not interpret lockfile links or source text.

Resolved source graphs can contain cycles, including Network’s Clan `data-mesher` import back to Network. The native closure terminates on repeated source headers while retaining actual named bindings; naive recursive tree projection would not terminate. The JSON header uses `path` for Nix's actual `outPath`, because Nix coerces an attribute set containing `outPath` to a string during JSON serialization.

The coordinated Apps contract is evaluated once, after the fresh and upgraded sources converge. All three candidate lockfiles must remain byte-identical after another ordinary lock operation. Logs, source projections, fixture declarations, lockfiles and whole/stage durations remain in the run directory printed by the script. `APPS_CONSUMER_ARTIFACT_ROOT` may select another ignored evidence directory.

This gate checks these representative Apps fixtures. It does not establish arbitrary consumer migration, lock-node bijection, equality of `original`/`parent` lock text, consumer configuration compatibility, builds, deployment or runtime application behavior. A consumer with direct Network and Primitives inputs must update the coordinated pins together, verify its own configuration and satisfy the database and ACME migration requirements in [README](../README.md#dependencies-and-migration). The gate uses no copied stubs, consumer `follows` overrides, manual lock reconstruction or adopted foreign consumer lock.

## Why the gate is required

A standalone checkout can evaluate successfully while a fresh consumer fails to
resolve nested relative inputs. The gate exercises ordinary public imports and
locking rather than reconstructing lock nodes. Native source projections compare
what Nix actually resolves, including `follows`, cycles and subdirectory paths.
Network v1.0.1 retains Clan's native DataMesher input and inherited follows.
DataMesher remains disabled by default and is not an application runtime service.

Each release must pass this gate alongside the [ordinary checks](../README.md#verification-and-release-acceptance).
Historical relative-input diagnosis is retained in
[Apps #1](https://github.com/clanwright/apps/issues/1); this gate does not claim to
fix Nix's general relative-input behavior.
