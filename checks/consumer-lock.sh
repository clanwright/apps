#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
apps_ref=${1:-github:clanwright/apps/v0.1.0}
if (( $# > 1 )) || [[ $apps_ref != github:clanwright/apps/* ]]; then
  printf 'usage: %s [github:clanwright/apps/<tag-or-revision>]\n' "$0" >&2
  exit 2
fi

mkdir -p "$repo_root/state/consumer-lock"
run_dir=$(mktemp -d "$repo_root/state/consumer-lock/run.XXXXXXXX")
consumer_dir="$run_dir/consumer"
mkdir "$consumer_dir"
printf 'Evidence: %s\n' "$run_dir"
printf 'Apps reference: %s\n' "$apps_ref"
nix --version > "$run_dir/nix-version.log"
cat "$run_dir/nix-version.log"

export APPS_REF="$apps_ref"
python3 - "$consumer_dir/flake.nix" <<'PY'
import json
import os
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text('''{
  inputs.apps.url = %s;
  outputs = { self, apps }: {
    # Apps' public contract evaluates both recipes, null/retained lifecycles,
    # and composition with shared Network instances in its Clan fixture.
    checks.x86_64-linux.apps-contract = apps.checks.x86_64-linux.contract;
  };
}
''' % json.dumps(os.environ['APPS_REF']))
PY

nix_cmd=(nix --extra-experimental-features 'nix-command flakes')
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

# Begin with no consumer lock and use the ordinary Nix resolver without input
# overrides, follows, copied graphs, or lock-file surgery.
run_step initial-lock "${nix_cmd[@]}" flake lock "path:$consumer_dir"
cp "$consumer_dir/flake.lock" "$run_dir/initial-flake.lock"

printf 'published-metadata: '
if "${nix_cmd[@]}" flake metadata --json --no-update-lock-file "$apps_ref" \
  > "$run_dir/published-metadata.json" 2> "$run_dir/published-metadata.log"; then
  printf 'PASS\n'
else
  status=$?
  printf 'FAIL (%s); see %s\n' "$status" "$run_dir/published-metadata.log" >&2
  exit "$status"
fi

run_step source-identity python3 "$repo_root/checks/consumer/source-identity.py" \
  "$consumer_dir/flake.lock" "$run_dir/published-metadata.json"
run_step recipe-contract "${nix_cmd[@]}" eval --raw --no-update-lock-file \
  "path:$consumer_dir#checks.x86_64-linux.apps-contract.drvPath"

printf 'consumer-metadata: '
if "${nix_cmd[@]}" flake metadata --json --no-update-lock-file "path:$consumer_dir" \
  > "$run_dir/consumer-metadata.json" 2> "$run_dir/consumer-metadata.log"; then
  printf 'PASS\n'
else
  status=$?
  printf 'FAIL (%s); see %s\n' "$status" "$run_dir/consumer-metadata.log" >&2
  exit "$status"
fi

run_step repeat-lock "${nix_cmd[@]}" flake lock "path:$consumer_dir"
run_step lock-byte-identity cmp "$run_dir/initial-flake.lock" "$consumer_dir/flake.lock"
printf 'Consumer lock and both recipe evaluations passed.\n'
