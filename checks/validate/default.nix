# Small native root/namespace spike, independent of application database fixtures.
{ pkgs }:
let
  probe = pkgs.writeShellApplication {
    name = "apps-validator-probe";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.util-linux
    ];
    text = ''
      test "$(id -u)" = 65534
      test "$(id -g)" = 65534
      test "$(id -G)" = 65534
      grep -q '^CapEff:[[:space:]]*0000000000000000$' /proc/self/status
      grep -q '^CapBnd:[[:space:]]*0000000000000000$' /proc/self/status
      test -z "''${APPS_HOST_SECRET-}"
      test ! -e /etc/passwd
      test ! -e /var/lib/validator-private-sentinel
      test ! -e /run/credentials
      test ! -e /proc/self/fd/9
      test "$(readlink /proc/self/fd/0)" = /dev/null
      test -L /bin/sh
      test "$(cat "$1/format-version")" = fixture-v1
      test ! -w "$1/format-version"
      test ! -w "$1"
      test ! -w /nix/store
      test -w /tmp
      test "$(ip -o link show | wc -l)" = 1
      ip -o addr show dev lo | grep -q '127.0.0.1/'
      touch /tmp/writable
      # Deliberately escape the shell's process group. PID namespace teardown
      # must still terminate this descendant after the validator exits.
      setsid ${pkgs.bash}/bin/bash -c 'exec -a APPS_VALIDATOR_ORPHAN ${pkgs.bash}/bin/bash -c "touch /tmp/orphan-ready; ${pkgs.coreutils}/bin/sleep 600; :"' &
      for ((attempt = 0; attempt < 100; attempt++)); do
        if test -e /tmp/orphan-ready; then break; fi
        sleep 0.01
      done
      test -e /tmp/orphan-ready
      echo 'root-to-unprivileged isolation probe passed'
    '';
  };
  validator = import ../../recovery/validate.nix {
    inherit pkgs;
    inherit (pkgs) lib;
    id = "fixture-validator";
    validateCommand = "${probe}/bin/apps-validator-probe";
  };
  slowProbe = pkgs.writeShellScript "apps-validator-slow-probe" ''
    echo fixture-slow-validator-started
    exec -a APPS_VALIDATOR_SLOW ${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/sleep 600; :'
  '';
  slowValidator = import ../../recovery/validate.nix {
    inherit pkgs;
    inherit (pkgs) lib;
    id = "fixture-slow";
    validateCommand = slowProbe;
  };
  shortValidator = pkgs.runCommand "apps-validator-short-deadline" { } ''
    mkdir -p "$out/bin"
    sed 's/TimeoutStartSec=600s/TimeoutStartSec=2s/g' ${slowValidator}/bin/validate > "$out/bin/validate"
    test "$(grep -c 'TimeoutStartSec=2s' "$out/bin/validate")" = 1
    chmod +x "$out/bin/validate"
  '';
  failedHandoff = pkgs.runCommand "apps-validator-failed-handoff" { } ''
    mkdir -p "$out/bin"
    sed 's/--service-type=oneshot/--service-type=oneshot --property=AppsInvalidProperty=1/' \
      ${slowValidator}/bin/validate > "$out/bin/validate"
    test "$(grep -c 'AppsInvalidProperty=1' "$out/bin/validate")" = 1
    chmod +x "$out/bin/validate"
  '';
  cancelledHandoff = pkgs.runCommand "apps-validator-cancelled-handoff" { } ''
    mkdir -p "$out/bin"
    sed '/^[[:space:]]*handed_off=1$/a\    mkfifo "$scratch/before-handoff"; exec 8<> "$scratch/before-handoff"; touch /tmp/before-handoff-ready; read -r -t 600 blocked <&8 || true' \
      ${slowValidator}/bin/validate > "$out/bin/validate"
    test "$(grep -c 'touch /tmp/before-handoff-ready;' "$out/bin/validate")" = 1
    chmod +x "$out/bin/validate"
  '';
  preparationValidator = pkgs.runCommand "apps-validator-preparation-probe" { } ''
    mkdir -p "$out/bin"
    service=$(sed -n 's|.*-- \(/nix/store/[^ ]*/bin/apps-validation-service\).*|\1|p' ${slowValidator}/bin/validate)
    test -n "$service"
    sed '/^[[:space:]]*find "[$]input"/i\    echo preparation-ready; sleep 10' "$service" > "$out/service"
    chmod +x "$out/service"
    sed "s|$service|$out/service|" ${slowValidator}/bin/validate > "$out/bin/validate"
    chmod +x "$out/bin/validate"
  '';

  delayedLauncher = pkgs.runCommand "apps-validator-delayed-launcher" { } ''
    mkdir -p "$out/bin"
    sed '/trap - EXIT HUP INT TERM/a\      touch /tmp/launcher-ready; sleep 5' ${shortValidator}/bin/validate > "$out/bin/validate"
    chmod +x "$out/bin/validate"
  '';
  sameHostChecks = pkgs.writeShellApplication {
    name = "apps-validator-same-host-checks";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.util-linux
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      await() {
        for ((attempt = 0; attempt < 120; attempt++)); do
          if "$@"; then return 0; fi
          sleep 0.25
        done
        return 1
      }
      limits() {
        cg=/sys/fs/cgroup/system.slice/apps-validate.service
        test "$(cat "$cg/memory.max")" = 1073741824
        test "$(cat "$cg/memory.swap.max")" = 0
        test "$(cat "$cg/pids.max")" = 128
        read -r quota period < "$cg/cpu.max"
        test "$quota" = "$period"
        test "$(systemctl show apps-validate.service -p Nice --value)" = 10
        test "$(systemctl show apps-validate.service -p IOWeight --value)" = 10
      }
      preparation_ready() {
        grep -q preparation-ready /var/tmp/apps-validate-fixture-slow.*/service.log
      }
      ${preparationValidator}/bin/validate /root/restored > /tmp/prep.log 2>&1 &
      wrapper=$!
      await preparation_ready
      limits
      await pgrep -f '^APPS_VALIDATOR_SLOW '
      limits
      owner=$(systemctl show apps-validate.service -p MainPID --value)
      if ${validator}/bin/validate /root/restored > /tmp/concurrent.log 2>&1; then exit 1; fi
      grep -q 'already running' /tmp/concurrent.log
      test "$(systemctl show apps-validate.service -p MainPID --value)" = "$owner"
      kill -TERM "$wrapper"
      if wait "$wrapper"; then exit 1; fi
      grep -q 'teardown confirmed' /tmp/prep.log
      echo 'PASS effective preparation and semantic limits; cross-app concurrency preserves owner'

      ${delayedLauncher}/bin/validate /root/restored > /tmp/kill.log 2>&1 &
      wrapper=$!
      await test -f /tmp/launcher-ready
      kill -KILL "$wrapper"
      wait "$wrapper" || true
      if ${validator}/bin/validate /root/restored > /tmp/kill-concurrent.log 2>&1; then exit 1; fi
      grep -q 'already running' /tmp/kill-concurrent.log
      await systemctl is-failed apps-validate.service
      await flock -n /run/lock/apps-validate.lock true
      if ${validator}/bin/validate /root/restored > /tmp/native-barrier.log 2>&1; then exit 1; fi
      grep -q 'slot is occupied' /tmp/native-barrier.log
      if pgrep -f '^APPS_VALIDATOR_SLOW '; then exit 1; fi
      scratch=$(sed -n 's/Apps validation scratch: //p' /tmp/kill.log)
      test -d "$scratch"
      systemctl stop apps-validate.service
      systemctl reset-failed apps-validate.service || true
      echo 'PASS wrapper SIGKILL during handoff preserves launcher lock and native barrier'

      ${cancelledHandoff}/bin/validate /root/restored > /tmp/foreign-cancel.log 2>&1 &
      wrapper=$!
      await test -f /tmp/before-handoff-ready
      systemd-run --unit=apps-validate.service --property=Description=foreign-test-owner \
        -- ${pkgs.coreutils}/bin/sleep 60
      owner=$(systemctl show apps-validate.service -p MainPID --value)
      test "$owner" != 0
      kill -TERM "$wrapper"
      if wait "$wrapper"; then exit 1; fi
      test "$(systemctl show apps-validate.service -p MainPID --value)" = "$owner"
      test "$(systemctl show apps-validate.service -p Description --value)" = foreign-test-owner
      systemctl is-active apps-validate.service
      grep -q 'teardown unconfirmed' /tmp/foreign-cancel.log
      scratch=$(sed -n 's/Apps validation scratch: //p' /tmp/foreign-cancel.log)
      test -d "$scratch"
      systemctl stop apps-validate.service
      rm /tmp/before-handoff-ready
      echo 'PASS cancelled handoff preserves a foreign native unit'
    '';
  };

  occupiedCleanup = pkgs.runCommand "apps-validator-occupied-cleanup" { } ''
    mkdir -p "$out/bin"
    sed 's|cgroup="/sys/fs/cgroup/system.slice/[$]unit"|cgroup="/sys/fs/cgroup/system.slice"|' \
      ${validator}/bin/validate > "$out/bin/validate"
    test "$(grep -c -F 'cgroup="/sys/fs/cgroup/system.slice"' "$out/bin/validate")" = 1
    chmod +x "$out/bin/validate"
  '';

in
pkgs.testers.runNixOSTest {
  name = "apps-validator-isolation";
  # Standard test-driver TCG fallback for builders without nested KVM.
  # Results prove Linux namespace behavior, not hardware acceleration.
  requiredFeatures = {
    kvm = false;
    nixos-test = false;
  };
  nodes.machine = {
    environment.systemPackages = [
      validator
      pkgs.procps
    ];
    virtualisation.memorySize = 2048;
  };
  testScript = ''
    import re
    start_all()
    def retained(output):
        match = re.search(r"Apps validation scratch: (/var/tmp/apps-validate-[a-zA-Z0-9.-]+)", output)
        assert match, output
        scratch = match.group(1)
        machine.succeed(f"test -d {scratch}; test $(stat -c %a {scratch}) = 700")
        return scratch

    machine.succeed("mkdir -m 700 /root/restored; printf fixture-v1 > /root/restored/format-version; chmod 600 /root/restored/format-version")
    machine.succeed("touch /var/lib/validator-private-sentinel")
    result = machine.succeed("APPS_HOST_SECRET=fixture DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent validate /root/restored 9</var/lib/validator-private-sentinel")
    assert "root-to-unprivileged isolation probe passed" in result, result
    machine.fail("pgrep -f '^APPS_VALIDATOR_ORPHAN '")
    machine.succeed("test $(stat -c %a /root/restored) = 700; test $(stat -c %a /root/restored/format-version) = 600")
    machine.succeed("test -z \"$(find /var/tmp -maxdepth 1 -name 'apps-validate-fixture-validator.*' -print -quit)\"")
    machine.succeed("ln -s /var/lib/validator-private-sentinel /root/restored/host-link")
    machine.fail("validate /root/restored")
    machine.succeed("rm /root/restored/host-link; ln /root/restored/format-version /root/restored/hardlink")
    machine.fail("validate /root/restored")
    machine.succeed("rm /root/restored/hardlink; mkfifo /root/restored/fifo")
    machine.fail("validate /root/restored")
    machine.succeed("rm /root/restored/fifo")

    machine.succeed("${sameHostChecks}/bin/apps-validator-same-host-checks")

    status, output = machine.execute("${shortValidator}/bin/validate /root/restored 2>&1")
    assert status != 0 and "fixture-slow-validator-started" in output and "teardown confirmed" in output, (status, output)
    retained(output)
    machine.fail("pgrep -f '^APPS_VALIDATOR_SLOW '")
    print("PASS native runtime timeout stops validator and retains scratch")

    machine.succeed("(set +e; ${slowValidator}/bin/validate /root/restored & pid=$!; echo $pid > /tmp/term.pid; wait $pid; echo $? > /tmp/term.status) > /tmp/term.log 2>&1 &")
    machine.wait_until_succeeds("pgrep -f '^APPS_VALIDATOR_SLOW '")
    machine.succeed("kill -TERM $(cat /tmp/term.pid)")
    machine.wait_until_succeeds("test -f /tmp/term.status", timeout=60)
    machine.succeed("test $(cat /tmp/term.status) != 0")
    machine.fail("pgrep -f '^APPS_VALIDATOR_SLOW '")
    retained(machine.succeed("cat /tmp/term.log"))
    print("PASS wrapper TERM requests native stop and retains scratch")

    machine.succeed("(set +e; ${slowValidator}/bin/validate /root/restored; echo $? > /tmp/monitor.status) > /tmp/monitor.log 2>&1 &")
    machine.wait_until_succeeds("pgrep -f '^APPS_VALIDATOR_SLOW '")
    output = machine.succeed("cat /tmp/monitor.log")
    match = re.search(r"Apps validation unit: (apps-validate.service)", output)
    assert match, output
    unit = match.group(1)
    machine.succeed(f"kill -KILL $(systemctl show {unit} -p MainPID --value)")
    machine.wait_until_succeeds("test -f /tmp/monitor.status", timeout=60)
    machine.succeed("test $(cat /tmp/monitor.status) != 0")
    machine.fail("pgrep -f '^APPS_VALIDATOR_SLOW '")
    retained(machine.succeed("cat /tmp/monitor.log"))
    print("PASS killed bwrap monitor cannot cause early scratch removal")

    status, output = machine.execute("${failedHandoff}/bin/validate /root/restored 2>&1")
    assert status != 0 and "AppsInvalidProperty" in output, (status, output)
    retained(output)
    machine.fail("pgrep -f '^APPS_VALIDATOR_SLOW '")
    print("PASS failed native handoff retains scratch")

    machine.succeed("(set +e; ${cancelledHandoff}/bin/validate /root/restored & pid=$!; echo $pid > /tmp/precreation.pid; wait $pid; echo $? > /tmp/precreation.status) > /tmp/precreation.log 2>&1 &")
    machine.wait_until_succeeds("test -f /tmp/before-handoff-ready")
    machine.succeed("kill -TERM $(cat /tmp/precreation.pid)")
    machine.wait_until_succeeds("test -f /tmp/precreation.status", timeout=15)
    machine.succeed("test $(cat /tmp/precreation.status) != 0")
    retained(machine.succeed("cat /tmp/precreation.log"))
    machine.fail("pgrep -f '^APPS_VALIDATOR_SLOW '")
    print("PASS cancellation before native unit creation retains scratch")
    machine.succeed("grep -qx 'populated 1' /sys/fs/cgroup/system.slice/cgroup.events")
    status, output = machine.execute("${occupiedCleanup}/bin/validate /root/restored 2>&1")
    assert status != 0 and "root-to-unprivileged isolation probe passed" in output and "teardown unconfirmed" in output, (status, output)
    retained(output)
    machine.fail("pgrep -f '^APPS_VALIDATOR_ORPHAN '")
    print("PASS successful validation with populated cleanup cgroup retains scratch")
    print("PASS root handoff, isolation, detached descendants, read-only copy, input preservation and successful cleanup")
  '';
}
