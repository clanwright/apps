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
    sed 's/RuntimeMaxSec=600s/RuntimeMaxSec=2s/g' ${slowValidator}/bin/validate > "$out/bin/validate"
    test "$(grep -c 'RuntimeMaxSec=2s' "$out/bin/validate")" = 1
    chmod +x "$out/bin/validate"
  '';
  failedHandoff = pkgs.runCommand "apps-validator-failed-handoff" { } ''
    mkdir -p "$out/bin"
    sed 's/--service-type=exec/--service-type=exec --property=AppsInvalidProperty=1/' \
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
    virtualisation.memorySize = 1024;
  };
  testScript = ''
    import re
    start_all()
    def retained(output):
        match = re.search(r"Apps validation scratch: (/var/tmp/apps-validate-[a-zA-Z0-9.-]+)", output)
        assert match, output
        scratch = match.group(1)
        machine.succeed(f"test -d {scratch}/input; test $(stat -c %a {scratch}) = 700")
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
    machine.succeed("test -z \"$(find /var/tmp -maxdepth 1 -name 'apps-validate-fixture-validator.*' -print -quit)\"")
    status, output = machine.execute("${shortValidator}/bin/validate /root/restored 2>&1")
    assert status != 0 and "fixture-slow-validator-started" in output and "timeout" in output.lower(), (status, output)
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
    match = re.search(r"Apps validation unit: (apps-validate-[a-zA-Z0-9.-]+)", output)
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
