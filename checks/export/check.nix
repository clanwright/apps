{ pkgs }:
let
  lib = pkgs.lib;
  handler = pkgs.writeShellScriptBin "export-fixture-handler" "exit 0";
  unit = {
    formatVersion = "fixture-v1";
    captureCommand = "${handler}/bin/export-fixture-handler";
    validateCommand = "${handler}/bin/export-fixture-handler";
  };
  vaultwarden = import ../../recovery/export.nix {
    inherit lib pkgs unit;
    id = "vaultwarden";
  };
  livesync = import ../../recovery/export.nix {
    inherit lib pkgs unit;
    id = "livesync";
  };
  v = vaultwarden.serviceConfig;
  l = livesync.serviceConfig;
in
pkgs.runCommand "apps-export-tools" { } ''
  test -x ${v.ExecStartPre}
  test -x ${v.ExecStartPost}
  test -x ${v.ExecStopPost}
  test -x ${l.ExecStartPre}
  test -x ${l.ExecStartPost}
  test -x ${l.ExecStopPost}
  test -x ${vaultwarden.package}/bin/prepare-reader
  test -x ${vaultwarden.package}/bin/validate
  test ! -e ${vaultwarden.package}/bin/capture
  test -x ${livesync.package}/bin/prepare-reader
  test -x ${livesync.package}/bin/validate
  test ! -e ${livesync.package}/bin/capture
  mkdir -p "$out"
  echo 'Apps export hooks and command packages built' > "$out/check.log"
''
