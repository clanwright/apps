#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
apps_ref=${1:-}
baseline_ref=${2:-github:clanwright/apps/4f8acab8d06dfc78961b518001417bb0c30388ea} # v0.5.1
safe_ref() {
  [[ $1 =~ ^github:clanwright/apps/[[:alnum:]._-]+$ || $1 =~ ^git\+file:/[[:alnum:]/.:?\&=_%+-]+$ ]]
}
if (( $# < 1 || $# > 2 )) || ! safe_ref "$apps_ref" || ! safe_ref "$baseline_ref"; then
  printf 'usage: %s [github:clanwright/apps/<revision>|git+file:<candidate>] [Apps-baseline-reference]\n' "$0" >&2
  exit 2
fi

artifact_root=${APPS_CONSUMER_ARTIFACT_ROOT:-"$repo_root/state/consumer-lock"}
if ! safe_ref "git+file:$artifact_root"; then
  printf 'artifact directory must be an absolute path with safe literal reference characters\n' >&2
  exit 2
fi
mkdir -p "$artifact_root"
run_dir=$(mktemp -d "$artifact_root/run.XXXXXXXX")
printf 'Evidence: %s\nApps reference: %s\nBaseline: %s\n' "$run_dir" "$apps_ref" "$baseline_ref"
nix --version | tee "$run_dir/nix-version.log"
nix_cmd=(nix --extra-experimental-features 'nix-command flakes')
if [[ $apps_ref == git+file:* || $baseline_ref == git+file:* ]]; then
  nix_cmd+=(--allow-dirty-locks)
fi
TIMEFORMAT=%3R
whole_started=$SECONDS
finish() {
  printf 'whole\t%s\n' "$((SECONDS - whole_started))" >> "$run_dir/timings.tsv"
}
trap finish EXIT
run_step() {
  local name=$1 status=0
  shift
  { time "$@" > "$run_dir/$name.log" 2>&1; } 2> "$run_dir/$name.seconds" || status=$?
  printf '%s\t%s\n' "$name" "$(cat "$run_dir/$name.seconds")" >> "$run_dir/timings.tsv"
  printf '%s: %s\n' "$name" "$([[ $status == 0 ]] && printf PASS || printf FAIL)"
  if (( status != 0 )); then
    printf 'See %s\n' "$run_dir/$name.log" >&2
    return "$status"
  fi
}
project_sources() {
  APPS_CONSUMER_REF="$1" "${nix_cmd[@]}" eval --impure --json --no-update-lock-file \
    --file "$repo_root/checks/consumer/source-tree.nix" \
    --apply 'f: f { ref = builtins.getEnv "APPS_CONSUMER_REF"; }' > "$2"
}
direct_ref() {
  local revision
  revision=$(jq -er --arg name "$2" '.inputs[$name].root.rev | select(test("^[0-9a-f]{40}$"))' "$1") || return
  printf 'github:clanwright/%s/%s' "$2" "$revision"
}
write_fixture() {
  local dir=$1 ref=$2 sources=$3 coordinated=$4 sentinel=${5:-}
  local network primitives
  if [[ $coordinated == yes ]]; then
    network=$(direct_ref "$sources" network) || return
    primitives=$(direct_ref "$sources" primitives) || return
  fi
  mkdir -p "$dir"
  {
    printf '{\n  inputs.apps.url = "%s";\n' "$ref"
    if [[ $coordinated == yes ]]; then
      printf '  inputs.network.url = "%s";\n' "$network"
      printf '  inputs.primitives.url = "%s";\n' "$primitives"
    fi
    if [[ -n $sentinel ]]; then
      printf '  inputs.sentinel.url = "path:%s";\n' "$sentinel"
    fi
    printf '  outputs = { apps, ... }: {\n    checks.x86_64-linux.apps-contract = apps.checks.x86_64-linux.contract;\n  };\n}\n'
  } > "$dir/flake.nix"
}
verify_sources() {
  jq -e --arg coordinated "$2" --slurpfile candidate "$run_dir/candidate-sources.json" \
    '.inputs.apps == $candidate[0].self and ($coordinated != "yes" or
      (.inputs.network == $candidate[0].inputs.network and
       .inputs.primitives == $candidate[0].inputs.primitives))' "$1"
}
relock() {
  local scenario=$1 dir="$run_dir/$1"
  cp "$dir/flake.lock" "$run_dir/$scenario-before-relock.lock"
  run_step "$scenario-relock" "${nix_cmd[@]}" flake lock "path:$dir"
  run_step "$scenario-byte-identity" cmp "$run_dir/$scenario-before-relock.lock" "$dir/flake.lock"
}

run_step candidate-sources project_sources "$apps_ref" "$run_dir/candidate-sources.json"
run_step baseline-sources project_sources "$baseline_ref" "$run_dir/baseline-sources.json"
for scenario in apps-only coordinated; do
  coordinated=no
  [[ $scenario != coordinated ]] || coordinated=yes
  write_fixture "$run_dir/$scenario" "$apps_ref" "$run_dir/candidate-sources.json" "$coordinated"
  run_step "$scenario-lock" "${nix_cmd[@]}" flake lock "path:$run_dir/$scenario"
  run_step "$scenario-sources" project_sources "path:$run_dir/$scenario" "$run_dir/$scenario-sources.json"
  run_step "$scenario-identity" verify_sources "$run_dir/$scenario-sources.json" "$coordinated"
  relock "$scenario"
done

mkdir -p "$run_dir/sentinel"
printf '{ outputs = { ... }: { marker = "independent-source"; }; }\n' > "$run_dir/sentinel/flake.nix"
write_fixture "$run_dir/upgrade" "$baseline_ref" "$run_dir/baseline-sources.json" yes "$run_dir/sentinel"
run_step upgrade-baseline-lock "${nix_cmd[@]}" flake lock "path:$run_dir/upgrade"
cp "$run_dir/upgrade/flake.lock" "$run_dir/upgrade-baseline.lock"
cp "$run_dir/upgrade/flake.nix" "$run_dir/upgrade-baseline.nix"
run_step upgrade-baseline-sources project_sources "path:$run_dir/upgrade" "$run_dir/upgrade-baseline-sources.json"
write_fixture "$run_dir/upgrade" "$apps_ref" "$run_dir/candidate-sources.json" yes "$run_dir/sentinel"
run_step upgrade-update "${nix_cmd[@]}" flake update apps network primitives --flake "path:$run_dir/upgrade"
run_step upgrade-sources project_sources "path:$run_dir/upgrade" "$run_dir/upgrade-sources.json"
run_step upgrade-identity verify_sources "$run_dir/upgrade-sources.json" yes
# shellcheck disable=SC2016 # The expression uses a jq variable.
run_step upgrade-sentinel jq -e --slurpfile before "$run_dir/upgrade-baseline-sources.json" \
  '.inputs.sentinel == $before[0].inputs.sentinel' "$run_dir/upgrade-sources.json"
relock upgrade

# Evaluate once, after both fresh and upgraded sources have converged.
run_step coordinated-contract "${nix_cmd[@]}" eval --raw --no-update-lock-file \
  "path:$run_dir/coordinated#checks.x86_64-linux.apps-contract.drvPath"
printf 'Fresh locking, resolved source equality, representative upgrade, contract evaluation, and stable relocking passed.\n'
