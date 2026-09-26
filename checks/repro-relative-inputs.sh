#!/usr/bin/env bash
set -eu

# Three-level, local-only reproducer for a locked middle flake's relative input.
# Each invocation creates a fresh fixture and readable logs under state/repro.
repo_root=$(cd "$(dirname "$0")/.." && pwd)
artifact_root=${1:-"$repo_root/state/repro"}
mkdir -p "$artifact_root"
artifact_root=$(cd "$artifact_root" && pwd)
run_dir=$(mktemp -d "$artifact_root/relative-inputs.XXXXXX")
export XDG_CACHE_HOME="$run_dir/cache"
mkdir -p "$XDG_CACHE_HOME"

library_dir="$run_dir/library"
wrapper_dir="$run_dir/wrapper"
consumer_dir="$run_dir/consumer"
mkdir -p "$library_dir/stubs/child" "$wrapper_dir" "$consumer_dir"

cat > "$library_dir/stubs/child/flake.nix" <<'EOF'
{
  outputs = { self }: { marker = "library-child"; };
}
EOF
cat > "$library_dir/flake.nix" <<'EOF'
{
  inputs.child.url = "./stubs/child";
  outputs = { self, child }: { inherit (child) marker; };
}
EOF
cat > "$wrapper_dir/flake.nix" <<EOF
{
  inputs.library.url = "git+file://$library_dir";
  outputs = { self, library }: { inherit (library) marker; };
}
EOF
cat > "$consumer_dir/flake.nix" <<EOF
{
  inputs.wrapper.url = "git+file://$wrapper_dir";
  outputs = { self, wrapper }: { inherit (wrapper) marker; };
}
EOF

for dir in "$library_dir" "$wrapper_dir"; do
  git -C "$dir" init -q
  git -C "$dir" add flake.nix
  if [ "$dir" = "$library_dir" ]; then
    git -C "$dir" add stubs/child/flake.nix
  fi
  git -C "$dir" -c user.name=Repro -c user.email=repro@example.invalid \
    commit -qm initial
done

nix_cmd=(nix --extra-experimental-features 'nix-command flakes')
printf 'run_dir=%s\nnix=%s\n' "$run_dir" "$(nix --version)" > "$run_dir/summary.log"
printf 'artifacts: %s\n' "$run_dir"

# Control: Nix computes the nested lock itself when Wrapper has no lock.
if "${nix_cmd[@]}" eval --raw "path:$consumer_dir#marker" \
  > "$run_dir/without-middle-lock.log" 2>&1; then
  printf 'without_middle_lock=pass\n' >> "$run_dir/summary.log"
else
  status=$?
  printf 'without_middle_lock=fail:%s\n' "$status" >> "$run_dir/summary.log"
  cat "$run_dir/summary.log"
  exit "$status"
fi

# Preserve the same inputs, but commit Wrapper's independently generated lock.
rm -f "$consumer_dir/flake.lock"
"${nix_cmd[@]}" flake lock "path:$wrapper_dir" \
  > "$run_dir/middle-lock.log" 2>&1
git -C "$wrapper_dir" add flake.lock
git -C "$wrapper_dir" -c user.name=Repro -c user.email=repro@example.invalid \
  commit -qm 'add middle lock'

# Nix 2.34.7+1 anchors Library's relative child at Wrapper here.
if "${nix_cmd[@]}" eval --raw "path:$consumer_dir#marker" \
  > "$run_dir/with-middle-lock.log" 2>&1; then
  printf 'with_middle_lock=pass\n' >> "$run_dir/summary.log"
  cat "$run_dir/summary.log"
  exit 0
else
  status=$?
  printf 'with_middle_lock=fail:%s\n' "$status" >> "$run_dir/summary.log"
  cat "$run_dir/summary.log"
  exit "$status"
fi
