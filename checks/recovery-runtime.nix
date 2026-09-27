{
  self,
  clan-core,
  primitives,
  apps-nixpkgs,
  system ? "x86_64-linux",
}:
let
  lib = clan-core.inputs.nixpkgs.lib;
  pkgs = import apps-nixpkgs { inherit system; };
  tools = primitives.lib.mkRecoveryTools { inherit system; };
  fixtureRoot = "/tmp/apps-recovery-runtime-${
    builtins.substring 0 16 (builtins.hashString "sha256" self.outPath)
  }";
  controller = pkgs.writeShellApplication {
    name = "apps-recovery-fixture-systemctl";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -eu
      root=${lib.escapeShellArg fixtureRoot}
      action="''${1:?}"
      unit="''${2:?}"
      case "$unit" in vaultwarden.service|couchdb.service) ;; *) exit 2 ;; esac
      name="''${unit%.service}"
      state="$root/$name.state"
      printf '%s %s\n' "$action" "$name" >> "$root/service-events"
      case "$action" in
        is-active) cat "$state" ;;
        stop)
          if test -e "$root/block-$name-stop"; then
            printf '%s\n' "$$" > "$root/blocked-$name-pid"
            sleep 120
          fi
          test ! -e "$root/fail-$name-stop"
          printf '%s\n' inactive > "$state"
          ;;
        start)
          test ! -e "$root/fail-$name-start"
          printf '%s\n' active > "$state"
          ;;
        *) exit 2 ;;
      esac
    '';
  };
  vaultwarden = import ../recovery/vaultwarden.nix {
    inherit lib pkgs tools;
    appsPkgs = pkgs;
    config = { };
    settings = {
      database.name = "vaultwarden";
      database.user = "vaultwarden";
      lifecycle = "enabled";
    };
    serviceController = "${controller}/bin/apps-recovery-fixture-systemctl";
    appDirectory = "${fixtureRoot}/vaultwarden";
    lockPath = "${fixtureRoot}/vaultwarden.lock";
    stagedDump = "${fixtureRoot}/stage/pg-dump";
    nativePre = ''
      cp ${lib.escapeShellArg "${fixtureRoot}/source.pg-dump"} ${lib.escapeShellArg "${fixtureRoot}/stage/pg-dump"}
      if test -e ${lib.escapeShellArg "${fixtureRoot}/block-native-pre"}; then
        printf '%s\n' "$$" > ${lib.escapeShellArg "${fixtureRoot}/blocked-native-pre-pid"}
        sleep 120
      fi
      test ! -e ${lib.escapeShellArg "${fixtureRoot}/fail-native-pre"}
    '';
    nativePost = ''
      printf '%s\n' native-post >> ${lib.escapeShellArg "${fixtureRoot}/service-events"}
      test ! -e ${lib.escapeShellArg "${fixtureRoot}/fail-native-post"}
      rm -f ${lib.escapeShellArg "${fixtureRoot}/stage/pg-dump"}
    '';
  };
  livesync = import ../recovery/livesync.nix {
    inherit lib pkgs tools;
    appsPkgs = pkgs;
    config.services.couchdb = {
      package = pkgs.couchdb3;
      argsFile = "${pkgs.couchdb3}/etc/vm.args";
    };
    settings = {
      lifecycle = "enabled";
    };
    serviceController = "${controller}/bin/apps-recovery-fixture-systemctl";
    sourceDirectory = "${fixtureRoot}/couchdb";
    lockPath = "${fixtureRoot}/livesync.lock";
  };
in
pkgs.runCommand "clanwright-apps-recovery-runtime"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.bubblewrap
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.jq
      pkgs.postgresql_18
      pkgs.couchdb3
      pkgs.util-linux
    ];
    inherit fixtureRoot;
    vwCapture = vaultwarden.captureCommand;
    vwValidate = vaultwarden.validateCommand;
    lsCapture = livesync.captureCommand;
    lsValidate = livesync.validateCommand;
    nixShell = "${pkgs.bash}/bin/bash";
    ipExe = "${pkgs.iproute2}/bin/ip";
    sandboxPath = lib.makeBinPath [
      pkgs.iproute2
      pkgs.coreutils
      pkgs.gnugrep
    ];
    couchExe = "${pkgs.couchdb3}/bin/couchdb";
    couchCaFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    couchDefaultIni = "${pkgs.couchdb3}/etc/default.ini";
  }
  ''
    set -euo pipefail
    mkdir -p "$out" "$fixtureRoot"
    export HOME="$fixtureRoot/home"
    mkdir -p "$HOME"
    exec > >(tee "$out/check.log") 2>&1
    bash ${./recovery/runtime.sh}
  ''
