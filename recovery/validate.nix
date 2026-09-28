# Native Linux with its local systemd manager and cgroup-v2 view.
# Input must be quiescent and administrator-controlled, including its parents.
# Hostile concurrent mutation and nested input mounts are unsupported.
{
  lib,
  pkgs,
  id,
  validateCommand,
}:
assert builtins.match "[a-z][a-z0-9-]*" id != null;
let
  service = pkgs.writeShellApplication {
    name = "apps-validation-service";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
    ];
    text = ''
      input=$1
      scratch=$2
      umask 077
      # Verify kernel-enforced limits before scanning any restored data.
      service_cgroup="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"
      read -r quota period < "$service_cgroup/cpu.max"
      if [[ "$quota" != "$period" || $(cat "$service_cgroup/memory.max") != 1073741824 ||
            $(cat "$service_cgroup/memory.swap.max") != 0 ||
            $(cat "$service_cgroup/pids.max") != 128 ]]; then
        echo 'validation resource controls are unavailable or ineffective' >&2
        exit 1
      fi
      find "$input" \
        \( ! -type d ! -type f -o -type f -links +1 \) -print -quit > "$scratch/rejected"
      if [[ -s "$scratch/rejected" ]]; then
        echo 'restored artifact contains a link or special file' >&2
        exit 1
      fi
      mkdir "$scratch/input" "$scratch/tmp"
      cp -R --no-dereference -- "$input/." "$scratch/input/"
      find "$scratch/input" -type f -exec chmod 444 -- {} +
      find "$scratch/input" -type d -exec chmod 555 -- {} +
      chown 65534:65534 "$scratch/tmp"
      # Setup root lacks DAC override but needs chdir; outer scratch remains0700.
      chmod 755 "$scratch/tmp"

      exec ${pkgs.bubblewrap}/bin/bwrap \
          --unshare-pid --unshare-net --unshare-ipc --unshare-uts \
          --die-with-parent --new-session --clearenv \
          --cap-drop ALL --cap-add CAP_SETUID --cap-add CAP_SETGID --cap-add CAP_SETPCAP \
          --dir /nix --ro-bind /nix/store /nix/store \
          --ro-bind "$scratch/input" /input --bind "$scratch/tmp" /tmp \
          --proc /proc --dev /dev \
          --dir /bin --symlink ${pkgs.runtimeShell} /bin/sh \
          --setenv HOME /tmp --setenv TMPDIR /tmp \
          --setenv PATH ${lib.makeBinPath [ pkgs.coreutils ]} --chdir /tmp \
          ${pkgs.util-linux}/bin/setpriv \
            --reuid 65534 --regid 65534 --clear-groups \
            --bounding-set=-all --inh-caps=-all --ambient-caps=-all --no-new-privs \
            ${lib.escapeShellArg (toString validateCommand)} /input
    '';
  };
in
pkgs.writeShellApplication {
  name = "validate";
  excludeShellChecks = [ "SC2329" ]; # finish is invoked by the EXIT trap.
  runtimeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.bubblewrap
    pkgs.util-linux
    pkgs.systemd
  ];
  text = ''
    if [[ $# != 1 || "$1" != /* || "$1" == / ]]; then
      echo 'usage: validate ABSOLUTE_RESTORED_DIRECTORY' >&2
      exit 2
    fi
    if [[ $(id -u) != 0 || $(uname -s) != Linux || $(cat /proc/1/comm) != systemd ]]; then
      echo 'validate requires root on a Linux host with local systemd' >&2
      exit 1
    fi
    # The caller must see the same cgroups/mounts as the system manager. A
    # container talking to a host D-Bus is not a supported validation host.
    if [[ $(stat -f -c %T /sys/fs/cgroup) != cgroup2fs ||
          $(readlink /proc/self/ns/mnt) != "$(readlink /proc/1/ns/mnt)" ||
          $(readlink /proc/self/ns/cgroup) != "$(readlink /proc/1/ns/cgroup)" ||
          ! -d /sys/fs/cgroup/system.slice || -L /sys/fs/cgroup/system.slice ]]; then
      echo 'validate requires the local manager cgroup-v2 and mount namespaces' >&2
      exit 1
    fi
    for controller in cpu memory pids; do
      if ! grep -qw "$controller" /sys/fs/cgroup/cgroup.controllers; then
        echo "validate requires the cgroup-v2 $controller controller" >&2
        exit 1
      fi
    done
    input=$1
    if [[ ! -d "$input" || -L "$input" || $(stat -c %u -- "$input") != 0 ]]; then
      echo 'input must be a root-owned, quiescent restored directory' >&2
      exit 1
    fi
    umask 077
    unit=apps-validate.service
    cgroup="/sys/fs/cgroup/system.slice/$unit"
    # The same open file description survives wrapper death in the launcher.
    # Never unlink this lock: that would allow another inode to be locked.
    exec {lock_fd}> /run/lock/apps-validate.lock
    if ! flock -n "$lock_fd"; then
      echo 'Apps validation is already running' >&2
      exit 1
    fi
    manager() {
      timeout --kill-after=5s 40s env -i ${pkgs.systemd}/bin/systemctl --system "$@"
    }
    snapshot() {
      state=$(manager show "$unit" -p LoadState -p ActiveState -p Job -p Description) || {
        [[ "$state" == *'LoadState=not-found'* ]] || return 1
      }
    }
    if ! snapshot || ! grep -qx 'LoadState=not-found' <<< "$state"; then
      echo "Apps validation slot is occupied or manager unavailable: $unit; operator inspection required" >&2
      exit 1
    fi
    scratch=$(mktemp -d /var/tmp/apps-validate-${id}.XXXXXXXXXX)
    echo "Apps validation scratch: $scratch" >&2
    echo "Apps validation unit: $unit" >&2
    token="Apps validation $scratch"
    stopped=0
    handed_off=0
    completed=0
    child=
    owns_unit() {
      snapshot && grep -Fxq "Description=$token" <<< "$state"
    }
    stop_owned() {
      owns_unit || return 1
      manager stop "$unit" || return 1
      stopped=1
    }
    teardown() {
      snapshot || return 1
      if ! grep -Fxq "Description=$token" <<< "$state"; then
        (( stopped )) && grep -qx 'LoadState=not-found' <<< "$state" || return 1
      fi
      grep -Eq '^ActiveState=(inactive|failed)$' <<< "$state" || return 1
      grep -Eq '^Job=(0)?$' <<< "$state" || return 1
      if [[ ! -e "$cgroup" && ! -L "$cgroup" ]]; then
        :
      elif [[ -d "$cgroup" && ! -L "$cgroup" && -r "$cgroup/cgroup.events" ]] &&
           grep -qx 'populated 0' "$cgroup/cgroup.events"; then
        :
      else
        return 1
      fi
      # A failed unit is our native barrier until both proofs above succeed.
      if grep -qx 'ActiveState=failed' <<< "$state"; then
        manager reset-failed "$unit" || return 1
      fi
    }
    report_retained() {
      if teardown; then
        echo "Apps validation teardown confirmed; retained scratch (manual removal safe): $scratch" >&2
      else
        echo "Apps validation teardown unconfirmed; retain scratch and inspect native unit $unit: $scratch" >&2
      fi
    }
    finish() {
      trap "" HUP INT TERM
      if (( handed_off && ! completed )); then
        # An early stop may race startup. The launcher keeps the flock until
        # the bounded startup wait ends; repeat stop after it exits.
        if owns_unit; then manager --no-block stop "$unit" >&2 && stopped=1 || true; fi
        launcher_status=0
        if [[ -n "$child" ]]; then wait "$child" || launcher_status=$?; fi
        stop_owned >&2 || true
        if (( launcher_status == 124 || launcher_status == 137 )); then
          echo "Apps validation handoff unconfirmed; retained scratch: $scratch; inspect $unit" >&2
        else
          report_retained
        fi
      elif (( ! handed_off )); then
        rm -rf -- "$scratch"
      fi
    }
    trap finish EXIT
    trap 'exit 1' HUP INT TERM

    # Failure, cancellation and uncertain handoff retain scratch. RemainAfterExit
    # keeps the native slot occupied after successful startup even if we die.
    handed_off=1
    (
      trap - EXIT HUP INT TERM
      for descriptor in /proc/self/fd/*; do
        descriptor="''${descriptor##*/}"
        if (( descriptor > 2 && descriptor != lock_fd )); then exec {descriptor}>&-; fi
      done
      exec timeout --kill-after=5s 660s env -i ${pkgs.systemd}/bin/systemd-run --system --unit="$unit" \
        --service-type=oneshot --property=RemainAfterExit=yes --property="Description=$token" \
        --property=TimeoutStartSec=600s --property=TimeoutStopSec=30s \
        --property=CPUQuota=100% --property=MemoryMax=1G --property=MemorySwapMax=0 \
        --property=TasksMax=128 --property=Nice=10 --property=IOWeight=10 --property=OOMPolicy=kill \
        --property=StandardInput=null --property="StandardOutput=append:$scratch/service.log" \
        --property=StandardError=inherit \
        --property=Slice=system.slice --property=Restart=no --property=Delegate=no \
        --property=KillMode=control-group --property=SendSIGKILL=yes \
        -- ${service}/bin/apps-validation-service "$input" "$scratch"
    ) < /dev/null &
    child=$!
    result=0
    wait "$child" || result=$?
    child=
    completed=1
    if [[ -f "$scratch/service.log" ]]; then cat "$scratch/service.log"; fi
    # A timed-out launcher has not acknowledged handoff. Preserve any native
    # barrier; manager failure is an operator-recovery case, not safe cleanup.
    if (( result == 124 || result == 137 )); then
      if owns_unit; then manager --no-block stop "$unit" >&2 && stopped=1 || true; fi
      echo "Apps validation handoff unconfirmed; retained scratch: $scratch; inspect $unit" >&2
      exit 1
    fi
    if (( result == 0 )); then
      stop_owned >&2 || result=1
    fi
    if ! teardown; then
      echo "Apps validation teardown unconfirmed; retained scratch: $scratch; inspect $unit" >&2
      exit 1
    fi
    if (( result != 0 )); then
      echo "Apps validation failed; teardown confirmed; retained scratch (manual removal safe): $scratch" >&2
      exit "$result"
    fi
    rm -rf -- "$scratch"
  '';
}
