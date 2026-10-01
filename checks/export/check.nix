{ pkgs }:
let
  lib = pkgs.lib;
  handler = pkgs.writeShellApplication {
    name = "export-fixture-handler";
    text = "exit 0";
  };
  producer = {
    formatVersion = "fixture-v1";
    capture = handler;
    validate = handler;
    appUnit = "fixture.service";
    formatMarker = pkgs.writeText "export-fixture-marker" "fixture-v1\n";
  };
  vaultwarden = import ../../recovery/export.nix {
    inherit lib pkgs producer;
    id = "vaultwarden";
  };
  livesync = import ../../recovery/export.nix {
    inherit lib pkgs producer;
    id = "livesync";
  };
  v = vaultwarden.serviceConfig;
  l = livesync.serviceConfig;
  nativeVaultwarden = import ../../recovery/vaultwarden.nix {
    inherit lib pkgs;
    tools.mkPostgresqlValidator = _: handler;
    config = {
      services.postgresql = {
        package = pkgs.postgresql_18;
        settings.port = 15432;
      };
      clan.core.state.vaultwarden-app.folders = [ "/tmp/export-compile-fixture" ];
    };
  };
in
pkgs.runCommand "apps-export-tools" { } ''
  test -x ${v.ExecStartPre}
  test -x ${v.ExecStart}
  test -x ${v.ExecStartPost}
  test -x ${v.ExecStopPost}
  test -x ${l.ExecStartPre}
  test -x ${l.ExecStart}
  test -x ${l.ExecStartPost}
  test -x ${l.ExecStopPost}
  test -x ${vaultwarden.package}/bin/prepare-reader
  test -x ${vaultwarden.package}/bin/validate
  test ! -e ${vaultwarden.package}/bin/capture
  test -x ${livesync.package}/bin/prepare-reader
  test -x ${livesync.package}/bin/validate
  test ! -e ${livesync.package}/bin/capture
  # Compile the REAL native PG guard/actor/dump closure without executing it.
  test -x ${lib.getExe nativeVaultwarden.capture}
  mkdir -p "$out"
  echo 'Apps export hooks and command packages built' > "$out/check.log"
''
