# Disposable native Linux with its local systemd manager and cgroup-v2 view.
# Input must be quiescent and administrator-controlled, including its parents.
# Hostile concurrent mutation and nested input mounts are unsupported.
{
  lib,
  pkgs,
  id,
  validateCommand,
}:
assert builtins.match "[a-z][a-z0-9-]*" id != null;
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
      echo 'validate requires root on a disposable Linux host with local systemd' >&2
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
    input=$1
    if [[ ! -d "$input" || -L "$input" || $(stat -c %u -- "$input") != 0 ]]; then
      echo 'input must be a root-owned, quiescent restored directory' >&2
      exit 1
    fi
    umask 077
    scratch=$(mktemp -d /var/tmp/apps-validate-${id}.XXXXXXXXXX)
    unit="''${scratch##*/}.service"
    cgroup="/sys/fs/cgroup/system.slice/$unit"
    echo "Apps validation scratch: $scratch" >&2
    echo "Apps validation unit: $unit" >&2
    handed_off=0
    completed=0
    child=
    finish() {
      trap "" HUP INT TERM
      if (( handed_off )); then
        # Cancellation never authorizes deletion. Stop may race unit creation;
        # RuntimeMaxSec bounds a unit even if that stop request misses startup.
        if (( ! completed )); then
          env -i ${pkgs.systemd}/bin/systemctl --system --no-block stop "$unit" >&2 || true
          if [[ -n "$child" ]]; then wait "$child" || true; fi
          echo "Apps validation interrupted; retained scratch: $scratch" >&2
        fi
      else
        rm -rf -- "$scratch"
      fi
    }
    trap finish EXIT
    trap 'exit 1' HUP INT TERM

    timeout --kill-after=5s 600s find "$input" \
      \( ! -type d ! -type f -o -type f -links +1 \) -print -quit > "$scratch/rejected"
    if [[ -s "$scratch/rejected" ]]; then
      echo 'restored artifact contains a link or special file' >&2
      exit 1
    fi
    mkdir "$scratch/input" "$scratch/tmp"
    timeout --kill-after=5s 600s cp -R --no-dereference -- "$input/." "$scratch/input/"
    timeout --kill-after=5s 600s find "$scratch/input" -type f -exec chmod 444 -- {} +
    timeout --kill-after=5s 600s find "$scratch/input" -type d -exec chmod 555 -- {} +
    chown 65534:65534 "$scratch/tmp"
    # Setup root lacks DAC override but needs chdir; outer scratch remains0700.
    chmod 755 "$scratch/tmp"

    # From this point failure, cancellation and uncertain handoff retain scratch.
    handed_off=1
    (
      trap - EXIT HUP INT TERM
      for descriptor in /proc/self/fd/*; do
        descriptor="''${descriptor##*/}"
        if (( descriptor > 2 )); then exec {descriptor}>&-; fi
      done
      exec env -i ${pkgs.systemd}/bin/systemd-run --system --unit="$unit" --wait --pipe --collect \
        --service-type=exec --property=RuntimeMaxSec=600s \
        --property=TimeoutStartSec=30s --property=TimeoutStopSec=30s \
        --property=Slice=system.slice --property=Restart=no --property=Delegate=no \
        --property=KillMode=control-group --property=SendSIGKILL=yes \
        -- ${pkgs.bubblewrap}/bin/bwrap \
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
    ) < /dev/null &
    child=$!
    result=0
    wait "$child" || result=$?
    child=
    completed=1
    if (( result != 0 )); then
      echo "Apps validation failed; retained scratch: $scratch" >&2
      exit "$result"
    fi
    # Outside the service cgroup, after successful uncancelled completion only.
    # populated=0 covers every live descendant, unlike process lists/FIFO EOF.
    if [[ ! -e "$cgroup" && ! -L "$cgroup" ]]; then
      :
    elif [[ -d "$cgroup" && ! -L "$cgroup" && -r "$cgroup/cgroup.events" ]] &&
         grep -qx 'populated 0' "$cgroup/cgroup.events"; then
      :
    else
      echo "Apps validation teardown unconfirmed; retained scratch: $scratch" >&2
      exit 1
    fi
    rm -rf -- "$scratch"
  '';
}
