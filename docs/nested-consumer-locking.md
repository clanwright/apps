# Nested consumer locking

Tracking: [Apps #1](https://github.com/clanwright/apps/issues/1).

## Observed failure

On 2026-09-26, Nix `2.34.7+1` failed ordinary `nix flake lock` for a fresh consumer whose only input was `github:clanwright/apps/v0.1.0` (Apps revision `186577efaea8f81608b1bd12c4736b8ffca2491a`). The error resolved `apps/network/data-mesher` against the Apps source tree:

```text
error: path '«github:clanwright/apps/186577efaea8f81608b1bd12c4736b8ffca2491a»/stubs/data-mesher/flake.nix' does not exist
```

Standalone `nix flake check --all-systems --no-build --no-update-lock-file` passed evaluation, including the lifecycle and shared Network composition assertions. This run did not build or execute the HTTP runtime derivation. No dependency source, recipe, service identity, state, or secret metadata was changed.

## Independent reproduction

```sh
bash checks/repro-relative-inputs.sh
```

The script creates its own small local Git flakes under ignored `state/repro/`. It does not fetch or inspect Network or Primitives implementation. The graph is consumer → wrapper → library → relative child. With a committed wrapper lock, fresh consumer locking fails on Nix `2.34.7+1`; without that intermediate lock, the same topology succeeds. This isolates reuse of the nested lock as a necessary trigger in this fixture. An unpinned, lock-free wrapper is a diagnostic control, not a release fix.

The script retains both cases and logs and returns nonzero when the regression is present. A future Nix fix should make both cases pass. This synthetic success alone would still not prove acceptance of the published Apps dependency graph.

## Stable Nix 2.35.2 verification

On 2026-09-26, the official `aarch64-darwin` Nix `2.35.2` release was tested separately from the installed `2.34.7+1`. The release executable was fetched from the signed official cache at `/nix/store/xbb13wrh7lv306phbapc006hfsscjd97-nix-2.35.2`; no installer, profile switch, or daemon update was performed.

Both checks still fail on `2.35.2`: the synthetic control without the intermediate lock passes, the locked variant resolves the child inside Wrapper and fails, and the published Apps consumer fails at initial locking with the same Apps-relative `stubs/data-mesher/flake.nix` error. Upgrading to this stable release does not resolve Apps #1. Later consumer gate stages are not reached.

Local evidence is retained at `state/repro/relative-inputs.P0yqP4/` and `state/consumer-lock/run.v7HBRnb0/`; top-level run logs are in `state/nix-2.35.2/`. These ignored artifacts are not release sources.

## Dependency refresh verification — 2026-09-27

The published v0.2.1 commit `86cf86c95b9ecbd686548cf2c0c5467d6dce754b` still fails fresh consumer locking on Nix `2.35.2` with the same Apps-relative child-path error. Using the exact commit avoids a GitHub API rate limit encountered while resolving the release tag.

A fresh local consumer of the initial dependency-refresh checkout (Clan `c612dac4b2bfb5278b7c366f250044ddb5401bcb`, Network v2.2.1 commit `54468aef7710a5ee1198b7354b1a4d09af29d1d8`, Apps nixpkgs `8d5d270900d3fc75655ea2d9d248b234f6631439`, and unchanged Primitives v0.1.0) also fails at `apps/network/data-mesher` on Nix `2.35.2`. The synthetic reproduction still passes without the intermediate lock and fails with it. This dependency refresh does not resolve Apps #1, and a local candidate test does not substitute for the published-revision release gate.

Evidence is retained under `state/dependency-upgrade/`: `baseline-published-sha-initial-lock.log`, `candidate-consumer-lock.log`, and `baseline-repro.log`. The system Nix installation was not changed for these isolated tests.

The subsequent candidate using Network v3.0.0 (`bfba5e74c3ee09ab92534fc2e7fdf31dc4525bb2`) and Primitives v0.2.0 (`9dd13dd84479914fe8465ff6f77d2bb1f8034e2e`) also fails at the same initial-lock step on Nix `2.35.2`. No consumer lock is generated, so its recipe evaluation, source-identity comparison, and byte-identical relocking stages cannot run. Standalone checks pass with CouchDB 3.5.2 and PostgreSQL 18.6; this does not waive the consumer gate. Evidence: `state/release-input-upgrade/flake-check.log` and `state/release-input-upgrade/consumer-initial-lock.log`.

## Upstream boundary

[Nix #14762](https://github.com/NixOS/nix/issues/14762) reports the same nested-relative-input topology. [Nix PR #15982](https://github.com/NixOS/nix/pull/15982) proposes refetching the declaring flake when a retained input has a relative child, so recursion receives its own source path. As checked on 2026-09-26, the PR is open and unmerged, at `3337ecd3b0ce0dea6200364ccb2afd82f43a692f`.

This points to Nix's lock-generation path, rather than a missing Apps-owned file. It is not evidence that a patched or future Nix version passes Apps acceptance. The PR also distinguishes its source-path fix from a remaining lock-parent rebasing optimization; do not describe the latter as the proven sole cause here.

## Handoff and closure

An existing consumer with a valid committed lock can continue using that lock, provided its own evaluation and build checks pass. This defect occurs during dependency locking; it does not itself require stopping running applications. Keep the working lock in version control and test dependency updates separately. Fresh adoption and lock regeneration remain blocked on the tested Nix versions; this is not an unconditional guarantee that every update of an existing consumer will succeed.

The v0.1.0 reproduction above used Network revision `7cbc2a01e9e18299b2ac606714081cc57470778d` and Primitives revision `6979fee86075ae62492e1572be434caf84c8337b`. Current accepted dependency pins are listed in [README](../README.md); preserve their source hashes and upstream dependency locks when validating a candidate. Do not copy Network implementation into Apps or add consumer `follows` overrides. No Network implementation change is proposed by this diagnosis.

The upstream follow-up is to validate a Nix version containing an accepted fix with the synthetic reproduction and then run `checks/consumer-lock.sh` against the published Apps revision. Record the exact Nix version and both results. A manually rebased consumer lock cannot substitute for fresh generation.

Apps #1 remains open until normal fresh locking, module evaluation, source-identity checks, and byte-identical relocking pass. The checks and diagnosis added here expose the blocker; they do not remove it. The release procedure in [README](../README.md#release-acceptance) requires this gate alongside standalone checks. No deployment or real credentials are required.
