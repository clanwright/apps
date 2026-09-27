#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
apps_ref=${1:-}
existing_lock=${2:-}
if (( $# < 1 || $# > 2 )) || [[ $apps_ref != github:clanwright/apps/* && $apps_ref != git+file:* ]]; then
  printf 'usage: %s [github:clanwright/apps/<tag-or-revision>|git+file:<candidate>] [existing-consumer-flake.lock]\n' "$0" >&2
  exit 2
fi
if [[ -n $existing_lock && ! -f $existing_lock ]]; then
  printf 'existing consumer lock not found: %s\n' "$existing_lock" >&2
  exit 2
fi

mkdir -p "$repo_root/state/consumer-lock"
run_dir=$(mktemp -d "$repo_root/state/consumer-lock/run.XXXXXXXX")
printf 'Evidence: %s\nApps reference: %s\n' "$run_dir" "$apps_ref"
nix --version > "$run_dir/nix-version.log"
cat "$run_dir/nix-version.log"
nix_cmd=(nix --extra-experimental-features 'nix-command flakes')
if [[ $apps_ref == git+file:* ]]; then
  nix_cmd+=(--allow-dirty-locks)
fi
run_step() {
  local name=$1
  shift
  printf '%s: ' "$name"
  if "$@" > "$run_dir/$name.log" 2>&1; then
    printf 'PASS\n'
  else
    local status=$?
    printf 'FAIL (%s); see %s\n' "$status" "$run_dir/$name.log" >&2
    return "$status"
  fi
}

# The candidate lock, whether published or local, supplies the coordinated
# direct Network and Primitives references. No consumer follows or overrides.
if "${nix_cmd[@]}" flake metadata --json --no-update-lock-file "$apps_ref" \
  > "$run_dir/candidate-metadata.json" 2> "$run_dir/candidate-metadata.log"; then
  printf 'candidate-metadata: PASS\n'
else
  status=$?
  printf 'candidate-metadata: FAIL (%s); see %s\n' "$status" "$run_dir/candidate-metadata.log" >&2
  exit "$status"
fi
run_step prepare python3 "$repo_root/checks/consumer/source-identity.py" prepare \
  "$run_dir/candidate-metadata.json" "$run_dir" "$apps_ref" "$existing_lock"

for scenario in apps-only coordinated; do
  consumer_dir="$run_dir/$scenario"
  run_step "$scenario-lock" "${nix_cmd[@]}" flake lock "path:$consumer_dir"
  cp "$consumer_dir/flake.lock" "$run_dir/$scenario-initial-flake.lock"
  run_step "$scenario-identity" python3 "$repo_root/checks/consumer/source-identity.py" verify \
    "$consumer_dir/flake.lock" "$run_dir/candidate-metadata.json" "$scenario"
  run_step "$scenario-contract" "${nix_cmd[@]}" eval --raw --no-update-lock-file \
    "path:$consumer_dir#checks.x86_64-linux.apps-contract.drvPath"
  run_step "$scenario-repeat-lock" "${nix_cmd[@]}" flake lock "path:$consumer_dir"
  run_step "$scenario-byte-identity" cmp "$run_dir/$scenario-initial-flake.lock" "$consumer_dir/flake.lock"
done

if [[ -n $existing_lock ]]; then
  existing_dir="$run_dir/existing"
  run_step existing-update "${nix_cmd[@]}" flake update apps network primitives \
    --flake "path:$existing_dir"
  cp "$existing_dir/flake.lock" "$run_dir/existing-updated-flake.lock"
  run_step existing-identity python3 "$repo_root/checks/consumer/source-identity.py" verify \
    "$existing_dir/flake.lock" "$run_dir/candidate-metadata.json" coordinated \
    "$run_dir/historical-flake.lock"
  run_step existing-contract "${nix_cmd[@]}" eval --raw --no-update-lock-file \
    "path:$existing_dir#checks.x86_64-linux.apps-contract.drvPath"
  run_step existing-repeat-lock "${nix_cmd[@]}" flake lock "path:$existing_dir"
  run_step existing-byte-identity cmp "$run_dir/existing-updated-flake.lock" "$existing_dir/flake.lock"
fi
printf 'Consumer locking, source convergence, contract evaluation, and relocking passed.\n'
