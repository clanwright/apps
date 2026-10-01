{
  self,
  clan-core,
  primitives,
  couchdbErlangFor,
  system ? "x86_64-linux",
}:
let
  lib = clan-core.inputs.nixpkgs.lib;
  # Evaluate the public DB modules under the same Clan host package authority
  # as the recipes. Only disposable actor/socket/port/state are substituted.
  clan = clan-core.lib.clan {
    self.inputs.self.clan = clan.config;
    specialArgs.clan-core = clan-core;
    directory = "${self.outPath}/checks";
    imports = [
      {
        machines.fixture = {
          imports = [
            primitives.nixosModules.postgresql
            primitives.nixosModules.couchdb
          ];
          nixpkgs.hostPlatform = system;
          boot.isContainer = true;
          system.stateVersion = "26.11";
          sops.defaultSopsFile = builtins.toFile "apps-recovery-fixture-sops.yaml" "sops:\n  age: []\n";
          sops.age.keyFile = "/run/fixture/age-key";
          services.clanwright.primitives = {
            postgresql.databases.vaultwarden = {
              lifecycle = "enabled";
              user = "vaultwarden";
              stateName = "vaultwarden-db";
              restoreStopUnits = [ "vaultwarden.service" ];
            };
            couchdb = {
              enable = true;
              lifecycle = "enabled";
              stateName = "obsidian";
              adminConfigSecretName = "obsidian-admin-ini";
            };
          };
          services.postgresql.settings.port = 15432;
        };
        inventory = {
          meta.name = "apps-recovery-runtime";
          machines.fixture = { };
        };
      }
    ];
  };
  machine = clan.config.nixosConfigurations.fixture;
  inherit (machine) config pkgs;
  postgres = config.services.postgresql.package;
  couchdb = config.services.couchdb.package;
  erlang = couchdbErlangFor pkgs.stdenv.hostPlatform.system;
  pgPort = toString config.services.postgresql.settings.port;
  tools = primitives.lib.mkRecoveryTools { inherit pkgs; };
  fixtureRoot = "/tmp/apps-recovery-runtime-${
    builtins.substring 0 16 (builtins.hashString "sha256" self.outPath)
  }";
  vaultwarden = import ../recovery/vaultwarden.nix {
    inherit
      lib
      pkgs
      tools
      config
      ;
    appDirectory = "${fixtureRoot}/vaultwarden";
    # Only the native actor/connector is substituted for the unprivileged
    # fixture. The real PostgreSQL server stays running throughout capture.
    databaseDump = pkgs.writeShellApplication {
      name = "apps-recovery-fixture-pg-dump";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        root=${lib.escapeShellArg fixtureRoot}
        # Only actor/connector differ; production's exact SQL guard is reused.
        idle=$(timeout --signal=TERM --kill-after=5s 20s ${postgres}/bin/psql -X --no-password -A -t \
          --set ON_ERROR_STOP=1 --host="$root/socket" --port=${pgPort} \
          --username="$(id -un)" --dbname=postgres --set app_db=vaultwarden --set app_role=vaultwarden \
          < ${../recovery/vaultwarden-quiescence.sql})
        test "$idle" = t || { echo 'fixture database has app backends or prepared transactions' >&2; exit 1; }
        if test -e "$root/fail-dump"; then
          printf '%s' partial-archive
          exit 1
        fi
        exec ${postgres}/bin/pg_dump --format=custom \
          --host="$root/socket" --port=${pgPort} --username="$(id -un)" --dbname=vaultwarden
      '';
    };
  };
  livesync = import ../recovery/livesync.nix {
    inherit
      lib
      pkgs
      tools
      config
      erlang
      ;
    sourceDirectory = "${fixtureRoot}/couchdb";
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
      pkgs.gnused
      pkgs.iproute2
      pkgs.jq
      postgres
      couchdb
      pkgs.util-linux
    ];
    inherit fixtureRoot pgPort;
    postgresVersion = postgres.version;
    couchdbVersion = couchdb.version;
    fixtureMetadata = builtins.toJSON {
      callerPkgsPath = toString pkgs.path;
      system = pkgs.stdenv.hostPlatform.system;
      postgresql = {
        package = toString postgres;
        derivation = builtins.unsafeDiscardStringContext postgres.drvPath;
        version = postgres.version;
        port = pgPort;
        disposableMaxPreparedTransactions = 1;
      };
      couchdb = {
        package = toString couchdb;
        derivation = builtins.unsafeDiscardStringContext couchdb.drvPath;
        version = couchdb.version;
        defaultIni = "${couchdb}/etc/default.ini";
        argsFile = toString config.services.couchdb.argsFile;
        erlang = {
          package = toString erlang;
          derivation = builtins.unsafeDiscardStringContext erlang.drvPath;
          version = erlang.version;
        };
      };
    };
    vwCapture = lib.getExe vaultwarden.capture;
    vwValidate = lib.getExe vaultwarden.validate;
    vwFormatMarker = vaultwarden.formatMarker;
    lsCapture = lib.getExe livesync.capture;
    lsValidate = lib.getExe livesync.validate;
    lsFormatMarker = livesync.formatMarker;
    nixShell = "${pkgs.bash}/bin/bash";
    ipExe = "${pkgs.iproute2}/bin/ip";
    sandboxPath = lib.makeBinPath [
      pkgs.iproute2
      pkgs.coreutils
      pkgs.gnugrep
    ];
    couchExe = "${couchdb}/bin/couchdb";
    couchCaFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    couchDefaultIni = "${couchdb}/etc/default.ini";
    couchArgsFile = toString config.services.couchdb.argsFile;
  }
  ''
    set -euo pipefail
    mkdir -p "$out" "$fixtureRoot"
    export HOME="$fixtureRoot/home"
    mkdir -p "$HOME"
    exec > >(tee "$out/check.log") 2>&1
    printf '%s\n' "$fixtureMetadata" > "$out/fixture-metadata.json"
    time -p bash ${./recovery/runtime.sh}
  ''
