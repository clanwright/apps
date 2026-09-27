{
  self,
  clan-core,
  network,
  primitives,
  apps-nixpkgs,
}:
let
  inherit (clan-core.inputs.nixpkgs) lib;
  pkgs = clan-core.inputs.nixpkgs.legacyPackages.x86_64-linux;
  context = {
    publicIPv4 = "192.0.2.10";
    certificateEmail = "fixture@example.invalid";
    privateIngress = {
      destinationIPv4 = "100.64.0.10";
      trustedInterfaces = [ "tailscale0" ];
    };
  };
  obsidian = {
    domain = "obsidian.example.invalid";
  };
  vaultwarden = {
    domain = "vaultwarden.example.invalid";
  };
  evaluate =
    selections: extraInventory: extraMachineImports:
    let
      clan = clan-core.lib.clan {
        self.inputs = {
          inherit network;
          apps = self;
          self.clan = clan.config;
        };
        specialArgs.clan-core = clan-core;
        directory = ./.;
        imports = [
          self.clanModules.default
          {
            clanwright.apps.machines = selections;
            machines.fixture = {
              imports = extraMachineImports;
              nixpkgs.hostPlatform = "x86_64-linux";
              boot.isContainer = true;
              system.stateVersion = "26.11";
              sops.defaultSopsFile = builtins.toFile "apps-fixture-sops.yaml" "sops:\n  age: []\n";
              sops.age.keyFile = "/run/fixture/age-key";
            };
            inventory = {
              meta.name = "apps-contract";
              machines.fixture = { };
              instances = extraInventory;
            };
          }
        ];
      };
    in
    {
      inherit clan;
      config = clan.config.nixosConfigurations.fixture.config;
    };
  empty = evaluate { } { } [ ];
  withdrawn = evaluate {
    fixture = {
      obsidian = null;
      vaultwarden = null;
    };
  } { } [ ];
  onlyObsidian = evaluate {
    fixture = {
      installation = context // {
        privateIngress = null;
      };
      inherit obsidian;
    };
  } { } [ ];
  onlyVaultwarden = evaluate {
    fixture = {
      installation = context;
      inherit vaultwarden;
    };
  } { } [ ];
  both = evaluate {
    fixture = {
      installation = context;
      inherit obsidian vaultwarden;
    };
  } { } [ ];
  exported = evaluate {
    fixture = {
      installation = context;
      obsidian = obsidian // {
        export.enable = true;
      };
      vaultwarden = vaultwarden // {
        export.enable = true;
      };
    };
  } { } [ ];
  withRestic = evaluate {
    fixture = {
      installation = context;
      obsidian = obsidian // {
        export.enable = true;
      };
      vaultwarden = vaultwarden // {
        export.enable = true;
      };
    };
  } { } [ ../examples/native-restic.nix ];
  retained = evaluate {
    fixture = {
      obsidian = obsidian // {
        lifecycle = "disabled-retained";
      };
      vaultwarden = vaultwarden // {
        lifecycle = "disabled-retained";
      };
    };
  } { } [ ];
  retainedExported = evaluate {
    fixture = {
      obsidian = obsidian // {
        lifecycle = "disabled-retained";
        export.enable = true;
      };
      vaultwarden = vaultwarden // {
        lifecycle = "disabled-retained";
        export.enable = true;
      };
    };
  } { } [ ];
  mixed = evaluate {
    fixture = {
      installation = context;
      obsidian = obsidian // {
        lifecycle = "disabled-retained";
      };
      inherit vaultwarden;
    };
  } { } [ ];
  conflictingTrust =
    evaluate
      {
        fixture = {
          installation = context;
          inherit vaultwarden;
        };
      }
      { }
      [
        {
          networkCore.firewall.privateIngressClaims.external = {
            destinationIPv4 = context.privateIngress.destinationIPv4;
            trustedInterfaces = [ "wg0" ];
          };
        }
      ];
  sameDomain = builtins.tryEval (
    builtins.deepSeq
      (evaluate {
        fixture = {
          installation = context;
          obsidian = obsidian // {
            inherit (vaultwarden) domain;
          };
          inherit vaultwarden;
        };
      } { } [ ]).config.services.caddy.virtualHosts
      true
  );
  coreInventory = email: {
    "fixture--network-certificates" = {
      module = {
        input = "network";
        name = "@clanwright/network-certificates";
      };
      roles.server.machines.fixture.settings = lib.optionalAttrs (email != null) { inherit email; };
    };
    "fixture--network-caddy" = {
      module = {
        input = "network";
        name = "@clanwright/network-caddy";
      };
      roles.ingress.machines.fixture.settings = { };
    };
    "fixture--network-firewall" = {
      module = {
        input = "network";
        name = "@clanwright/network-firewall";
      };
      roles.host.machines.fixture.settings = {
        rejectHttp = true;
        bootstrapSsh = {
          enable = true;
          publicIPv4 = "192.0.2.10";
        };
      };
    };
  };
  existingNetwork = evaluate {
    fixture = {
      installation = context;
      inherit obsidian vaultwarden;
    };
  } (coreInventory "fixture@example.invalid") [ ];
  coreOnly = evaluate { } (coreInventory "fixture@example.invalid") [ ];
  conflictingEmail = evaluate {
    fixture = {
      installation = context;
      inherit obsidian;
    };
  } (coreInventory "different@example.invalid") [ ];
  missingCoreEmail = builtins.tryEval (
    builtins.deepSeq
      (evaluate {
        fixture = {
          installation = context;
          inherit obsidian;
        };
      } (coreInventory null) [ ]).config.security.acme.defaults.email
      true
  );
  threeMachines =
    let
      names = [
        "alpha"
        "beta"
        "gamma"
      ];
      clan = clan-core.lib.clan {
        self.inputs = {
          inherit network;
          apps = self;
          self.clan = clan.config;
        };
        specialArgs.clan-core = clan-core;
        directory = ./.;
        imports = [
          self.clanModules.default
          {
            clanwright.apps.machines = {
              alpha = {
                installation = context // {
                  privateIngress = null;
                };
                inherit obsidian;
              };
              beta = {
                installation = context;
                inherit vaultwarden;
              };
              gamma = {
                installation = context;
                inherit obsidian vaultwarden;
              };
            };
            machines = lib.genAttrs names (_: {
              nixpkgs.hostPlatform = "x86_64-linux";
              boot.isContainer = true;
              system.stateVersion = "26.11";
              sops.defaultSopsFile = builtins.toFile "apps-three-sops.yaml" "sops:\n  age: []\n";
              sops.age.keyFile = "/run/fixture/age-key";
            });
            inventory = {
              meta.name = "apps-three-machine-contract";
              machines = lib.genAttrs names (_: { });
            };
          }
        ];
      };
    in
    clan.config;
  missingInstallation = builtins.tryEval (
    builtins.deepSeq
      (evaluate { fixture.obsidian = obsidian; } { } [ ])
      .config.networkCore.caddy.fragments."fixture--app-obsidian".listenAddresses
      true
  );
  missingPrivate = builtins.tryEval (
    builtins.deepSeq
      (evaluate {
        fixture = {
          installation = context // {
            privateIngress = null;
          };
          inherit vaultwarden;
        };
      } { } [ ]).config.networkCore.caddy.fragments."fixture--app-vaultwarden".listenAddresses
      true
  );
  sameListeners = builtins.tryEval (
    builtins.deepSeq
      (evaluate {
        fixture = {
          installation = context // {
            privateIngress = context.privateIngress // {
              destinationIPv4 = context.publicIPv4;
            };
          };
          inherit vaultwarden;
        };
      } { } [ ]).config.networkCore.caddy.fragments."fixture--app-vaultwarden".listenAddresses
      true
  );
  badPublic =
    address:
    builtins.tryEval (
      builtins.deepSeq
        (evaluate {
          fixture = {
            installation = context // {
              publicIPv4 = address;
              privateIngress = null;
            };
            inherit obsidian;
          };
        } { } [ ]).config.networkCore.caddy.fragments."fixture--app-obsidian".listenAddresses
        true
    );
  badPrivate =
    address:
    builtins.tryEval (
      builtins.deepSeq
        (evaluate {
          fixture = {
            installation = context // {
              privateIngress = context.privateIngress // {
                destinationIPv4 = address;
              };
            };
            inherit vaultwarden;
          };
        } { } [ ]).config.networkCore.caddy.fragments."fixture--app-vaultwarden".listenAddresses
        true
    );
  instances = value: builtins.attrNames value.clan.config.inventory.instances;
  failed = value: map (a: a.message) (builtins.filter (a: !a.assertion) value.config.assertions);
  recoveryUnits = value: value.config.clanwright.recovery.units or { };
  recoverySummary =
    value:
    lib.mapAttrs (_: unit: {
      inherit (unit)
        contractVersion
        formatVersion
        stateRefs
        captureCommand
        validateCommand
        ;
    }) (recoveryUnits value);
  backupTimers =
    value: lib.filter (lib.hasInfix "backup") (builtins.attrNames value.config.systemd.timers);
  backupServices =
    value: lib.filter (lib.hasInfix "backup") (builtins.attrNames value.config.systemd.services);
  exportServices =
    value: lib.filter (lib.hasPrefix "apps-export-") (builtins.attrNames value.config.systemd.services);
  exportTimers =
    value: lib.filter (lib.hasPrefix "apps-export-") (builtins.attrNames value.config.systemd.timers);
  exportBuilds =
    value: lib.filter (lib.hasPrefix "apps") (builtins.attrNames value.config.system.build);
  exportState =
    value: lib.filter (lib.hasPrefix "apps-export-") (builtins.attrNames value.config.clan.core.state);
  unexpectedRecoveryRuntime =
    value:
    let
      names =
        builtins.attrNames value.config.systemd.services ++ builtins.attrNames value.config.systemd.timers;
    in
    lib.filter (
      name:
      lib.any (marker: lib.hasInfix marker name) [
        "recovery"
        "restic"
        "borg"
        "rclone"
      ]
    ) names;
  validRecoveryUnit =
    unit:
    unit.contractVersion == 1
    && builtins.match "[A-Za-z0-9]+([._-][A-Za-z0-9]+)*" unit.formatVersion != null
    && builtins.match "/nix/store/[a-z0-9]{32}-[^/]+/bin/[^/]+" unit.captureCommand != null
    && builtins.match "/nix/store/[a-z0-9]{32}-[^/]+/bin/[^/]+" unit.validateCommand != null;
  report = {
    none = {
      instances = instances empty;
      recovery = recoverySummary empty;
    };
    withdrawn = {
      instances = instances withdrawn;
      recovery = recoverySummary withdrawn;
      state = builtins.attrNames withdrawn.config.clan.core.state;
      secrets = builtins.attrNames withdrawn.config.sops.secrets;
      caddyHosts = builtins.attrNames withdrawn.config.services.caddy.virtualHosts;
      claims = withdrawn.config.networkCore.firewall.privateIngressClaims or { };
      exportServices = exportServices withdrawn;
      exportState = exportState withdrawn;
    };
    obsidian = {
      instances = instances onlyObsidian;
      serviceName = onlyObsidian.clan.config.inventory.instances."fixture--app-obsidian".module.name;
      couchdb = onlyObsidian.config.services.couchdb.enable;
      postgresql = onlyObsidian.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames onlyObsidian.config.services.caddy.virtualHosts;
      claims = onlyObsidian.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed onlyObsidian;
      recovery = recoverySummary onlyObsidian;
      backupTimers = backupTimers onlyObsidian;
      backupServices = backupServices onlyObsidian;
    };
    vaultwarden = {
      instances = instances onlyVaultwarden;
      couchdb = onlyVaultwarden.config.services.couchdb.enable;
      postgresql = onlyVaultwarden.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames onlyVaultwarden.config.services.caddy.virtualHosts;
      claims = onlyVaultwarden.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed onlyVaultwarden;
      recovery = recoverySummary onlyVaultwarden;
      backupTimers = backupTimers onlyVaultwarden;
      backupServices = backupServices onlyVaultwarden;
    };
    both = {
      instances = instances both;
      caddyHosts = builtins.attrNames both.config.services.caddy.virtualHosts;
      claims = both.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed both;
      recovery = recoverySummary both;
      backupTimers = backupTimers both;
      backupServices = backupServices both;
      unexpectedRecoveryRuntime = unexpectedRecoveryRuntime both;
      exportServices = exportServices both;
      exportTimers = exportTimers both;
      exportState = exportState both;
      exportBuilds = exportBuilds both;
    };
    exported = {
      services = exportServices exported;
      timers = exportTimers exported;
      state = exportState exported;
      builds = exportBuilds exported;
      paths = {
        livesync = exported.config.clan.core.state.apps-export-livesync.folders;
        vaultwarden = exported.config.clan.core.state.apps-export-vaultwarden.folders;
      };
      units = lib.genAttrs [ "apps-export-livesync" "apps-export-vaultwarden" ] (
        name:
        let
          unit = exported.config.systemd.services.${name};
        in
        {
          inherit (unit) wantedBy;
          inherit (unit.serviceConfig)
            Type
            User
            Group
            UMask
            TimeoutStartSec
            TimeoutStopSec
            KillMode
            StateDirectory
            RuntimeDirectory
            ExecStartPre
            ExecStart
            ExecStartPost
            ExecStopPost
            ;
        }
      );
      packages = {
        livesync = exported.config.system.build.appsLiveSyncExport.outPath;
        vaultwarden = exported.config.system.build.appsVaultwardenExport.outPath;
      };
      recovery = recoverySummary exported;
      caddyHosts = builtins.attrNames exported.config.services.caddy.virtualHosts;
      claims = exported.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed exported;
    };
    withRestic = {
      names = builtins.attrNames withRestic.config.services.restic.backups;
      jobs = lib.mapAttrs (name: job: {
        inherit (job) timerConfig createWrapper paths;
        cacheDir = withRestic.config.systemd.services."restic-backups-${name}".environment.RESTIC_CACHE_DIR;
        prepare = job.backupPrepareCommand;
        cleanup = job.backupCleanupCommand;
      }) withRestic.config.services.restic.backups;
      timers = lib.filter (lib.hasPrefix "restic-backups-") (
        builtins.attrNames withRestic.config.systemd.timers
      );
      services = lib.genAttrs (map (name: "restic-backups-${name}") (
        builtins.attrNames withRestic.config.services.restic.backups
      )) (name: withRestic.config.systemd.services.${name}.serviceConfig);
      failedAssertions = failed withRestic;
    };
    retainedExported = {
      services = exportServices retainedExported;
      timers = exportTimers retainedExported;
      state = exportState retainedExported;
      builds = exportBuilds retainedExported;
      recovery = recoverySummary retainedExported;
      caddyHosts = builtins.attrNames retainedExported.config.services.caddy.virtualHosts;
      claims = retainedExported.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed retainedExported;
    };
    retained = {
      instances = instances retained;
      couchdb = retained.config.services.couchdb.enable;
      postgresql = retained.config.services.postgresql.enable;
      vaultwarden = retained.config.services.vaultwarden.enable;
      couchdbState = retained.config.clan.core.state.obsidian.folders;
      vaultwardenState = retained.config.clan.core.state.vaultwarden-app.folders;
      vaultwardenDbState = retained.config.clan.core.state.vaultwarden-db.folders;
      obsidianSecret = builtins.hasAttr "obsidian-admin-ini" retained.config.sops.secrets;
      vaultwardenSecret = builtins.hasAttr "vaultwarden-admin-token" retained.config.sops.secrets;
      vaultwardenSecretRestartUnits = retained.config.sops.secrets."vaultwarden-admin-token".restartUnits;
      vaultwardenDatabaseLifecycle =
        retained.config.services.clanwright.primitives.postgresql.databases.vaultwarden.lifecycle;
      caddyHosts = builtins.attrNames retained.config.services.caddy.virtualHosts;
      claims = retained.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed retained;
      recovery = recoverySummary retained;
    };
    mixed = {
      instances = instances mixed;
      couchdb = mixed.config.services.couchdb.enable;
      postgresql = mixed.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames mixed.config.services.caddy.virtualHosts;
      failedAssertions = failed mixed;
      recovery = recoverySummary mixed;
    };
    conflicts = {
      trust = failed conflictingTrust;
      sameDomain = sameDomain.success;
    };
    existingNetwork = {
      instances = instances existingNetwork;
      recovery = recoverySummary existingNetwork;
      certSettings =
        existingNetwork.clan.config.inventory.instances."fixture--network-certificates".roles.server.machines.fixture.settings;
      acmeEmail = existingNetwork.config.security.acme.defaults.email or null;
      firewallSettingsPreserved =
        let
          raw =
            builtins.toJSON
              existingNetwork.clan.config.inventory.instances."fixture--network-firewall".roles.host.machines.fixture.settings;
        in
        lib.hasInfix ''"rejectHttp":true'' raw && lib.hasInfix ''"bootstrapSsh"'' raw;
      failedAssertions = failed existingNetwork;
    };
    coreOnly = {
      instances = instances coreOnly;
      failedAssertions = failed coreOnly;
    };
    threeMachines = {
      instances = builtins.attrNames threeMachines.inventory.instances;
      failedAssertions = lib.genAttrs [ "alpha" "beta" "gamma" ] (
        machine:
        map (a: a.message) (
          builtins.filter (a: !a.assertion) threeMachines.nixosConfigurations.${machine}.config.assertions
        )
      );
    };
    certificateConflict = {
      failedAssertions = failed conflictingEmail;
      missingCoreEmail = missingCoreEmail.success;
    };
    rejected = {
      missingInstallation = missingInstallation.success;
      missingPrivate = missingPrivate.success;
      sameListeners = sameListeners.success;
      publicWildcard = (badPublic "0.0.0.0").success;
      publicInvalidOctet = (badPublic "999.1.2.3").success;
      privateWildcard = (badPrivate "0.0.0.0").success;
      privateInvalidOctet = (badPrivate "10.300.1.1").success;
      privateIPv6 = (badPrivate "::").success;
    };
    defaults = {
      obsidianSecret = builtins.hasAttr "obsidian-admin-ini" onlyObsidian.config.sops.secrets;
      vaultwardenSecret = builtins.hasAttr "vaultwarden-admin-token" onlyVaultwarden.config.sops.secrets;
      couchdbVersion = onlyObsidian.config.services.couchdb.package.version;
      postgresVersion = onlyVaultwarden.config.services.postgresql.package.version;
      vaultwardenVersion = onlyVaultwarden.config.services.vaultwarden.package.version;
      vaultwardenPackageMatchesExport =
        onlyVaultwarden.config.services.vaultwarden.package.outPath
        == self.packages.x86_64-linux.vaultwarden.outPath;
      couchdbState = onlyObsidian.config.clan.core.state.obsidian.folders;
      obsidianAccessLog = onlyObsidian.config.networkCore.caddy.fragments."fixture--app-obsidian".logFile;
      vaultwardenState = onlyVaultwarden.config.clan.core.state.vaultwarden-app.folders;
      vaultwardenDbState = onlyVaultwarden.config.clan.core.state.vaultwarden-db.folders;
      vaultwardenRestoreOrder =
        onlyVaultwarden.config.clan.core.postgresql.databases.vaultwarden.restore.stopOnRestore;
      vaultwardenUnitAfter = onlyVaultwarden.config.systemd.services.vaultwarden.after;
      vaultwardenUnitRequires = onlyVaultwarden.config.systemd.services.vaultwarden.requires;
      vaultwardenDbBackend = onlyVaultwarden.config.services.vaultwarden.dbBackend;
      vaultwardenDatabaseUrl = onlyVaultwarden.config.services.vaultwarden.config.DATABASE_URL;
      vaultwardenDatabase =
        let
          database = onlyVaultwarden.config.services.clanwright.primitives.postgresql.databases.vaultwarden;
        in
        {
          inherit (database) lifecycle user restoreStopUnits;
        };
      vaultwardenPublicAdmin404 =
        lib.hasInfix "respond @publicAdminPaths 404"
          onlyVaultwarden.config.services.caddy.virtualHosts."fixture--app-vaultwarden".extraConfig;
      vaultwardenPrivateGuard = lib.hasInfix "100.64.0.10" onlyVaultwarden.config.networking.nftables.tables.network-edge-policy.content;
      caddyPackageMatchesNetwork =
        onlyVaultwarden.config.services.caddy.package.outPath
        == network.packages.x86_64-linux.caddy-custom.outPath;
    };
    revisions = {
      inherit (clan-core) rev;
      network = network.rev;
      primitives = primitives.rev;
      appsNixpkgs = apps-nixpkgs.rev;
    };
  };
  check =
    assert report.none.instances == [ ];
    assert report.none.recovery == { };
    assert report.withdrawn.instances == [ ];
    assert report.withdrawn.recovery == { };
    assert report.withdrawn.state == [ ];
    assert report.withdrawn.secrets == [ ];
    assert report.withdrawn.caddyHosts == [ ] && report.withdrawn.claims == { };
    assert report.withdrawn.exportServices == [ ] && report.withdrawn.exportState == [ ];
    assert builtins.length report.obsidian.instances == 4;
    assert builtins.elem "fixture--app-obsidian" report.obsidian.instances;
    assert report.obsidian.serviceName == "@clanwright/apps-obsidian";
    assert builtins.hasAttr "@clanwright/apps-obsidian" self.clan.modules;
    assert
      builtins.attrNames self.clan.modules == [
        "@clanwright/apps-obsidian"
        "@clanwright/apps-vaultwarden"
      ];
    assert builtins.length report.vaultwarden.instances == 4;
    assert builtins.length report.both.instances == 5;
    assert
      report.retained.instances == [
        "fixture--app-obsidian"
        "fixture--app-vaultwarden"
      ];
    assert report.obsidian.couchdb && !report.obsidian.postgresql;
    assert !report.vaultwarden.couchdb && report.vaultwarden.postgresql;
    assert !report.retained.couchdb && !report.retained.postgresql && !report.retained.vaultwarden;
    assert report.retained.couchdbState == [ "/var/lib/couchdb" ];
    assert report.retained.vaultwardenState == [ "/var/lib/vaultwarden" ];
    assert report.retained.vaultwardenDbState == [ "/var/backup/postgres/vaultwarden" ];
    assert report.retained.obsidianSecret && report.retained.vaultwardenSecret;
    assert report.retained.vaultwardenSecretRestartUnits == [ ];
    assert report.retained.vaultwardenDatabaseLifecycle == "disabled-retained";
    assert report.retained.caddyHosts == [ ] && report.retained.claims == { };
    assert report.retained.recovery == { };
    assert report.obsidian.failedAssertions == [ ];
    assert report.vaultwarden.failedAssertions == [ ];
    assert report.both.failedAssertions == [ ];
    assert report.retained.failedAssertions == [ ];
    assert builtins.length report.mixed.instances == 5;
    assert !report.mixed.couchdb && report.mixed.postgresql;
    assert report.mixed.caddyHosts == [ "fixture--app-vaultwarden" ];
    assert report.mixed.failedAssertions == [ ];
    assert builtins.attrNames report.mixed.recovery == [ "vaultwarden" ];
    assert builtins.attrNames report.obsidian.recovery == [ "livesync" ];
    assert builtins.attrNames report.vaultwarden.recovery == [ "vaultwarden" ];
    assert
      builtins.attrNames report.both.recovery == [
        "livesync"
        "vaultwarden"
      ];
    assert builtins.all validRecoveryUnit (builtins.attrValues report.both.recovery);
    assert report.both.recovery.livesync.stateRefs == [ "obsidian" ];
    assert
      report.both.recovery.vaultwarden.stateRefs == [
        "vaultwarden-app"
        "vaultwarden-db"
      ];
    assert builtins.all (stateRef: builtins.hasAttr stateRef both.config.clan.core.state) (
      report.both.recovery.livesync.stateRefs ++ report.both.recovery.vaultwarden.stateRefs
    );
    assert report.obsidian.recovery == { livesync = report.both.recovery.livesync; };
    assert report.vaultwarden.recovery == { vaultwarden = report.both.recovery.vaultwarden; };
    assert report.mixed.recovery == report.vaultwarden.recovery;
    assert builtins.all (lib.hasPrefix "postgresql") (
      report.both.backupTimers ++ report.both.backupServices
    );
    assert report.both.unexpectedRecoveryRuntime == [ ];
    assert report.both.exportServices == [ ] && report.both.exportTimers == [ ];
    assert report.both.exportState == [ ] && report.both.exportBuilds == [ ];
    assert
      report.exported.services == [
        "apps-export-livesync"
        "apps-export-vaultwarden"
      ];
    assert report.exported.timers == [ ];
    assert report.exported.state == report.exported.services;
    assert
      report.exported.builds == [
        "appsLiveSyncExport"
        "appsVaultwardenExport"
      ];
    assert report.exported.paths.livesync == [ "/var/lib/clanwright-app-exports/livesync" ];
    assert report.exported.paths.vaultwarden == [ "/var/lib/clanwright-app-exports/vaultwarden" ];
    assert builtins.all (
      unit:
      unit.wantedBy == [ ]
      && unit.Type == "oneshot"
      && unit.User == "root"
      && unit.Group == "root"
      && unit.UMask == "0077"
      && unit.TimeoutStartSec == "1h"
      && unit.KillMode == "mixed"
    ) (builtins.attrValues report.exported.units);
    assert report.exported.units.apps-export-livesync.TimeoutStopSec == "90s";
    assert report.exported.units.apps-export-vaultwarden.TimeoutStopSec == "180s";
    assert
      report.exported.units.apps-export-livesync.ExecStart
      == "${report.exported.recovery.livesync.captureCommand} /var/lib/clanwright-app-exports/livesync/pending";
    assert
      report.exported.units.apps-export-vaultwarden.ExecStart
      == "${report.exported.recovery.vaultwarden.captureCommand} /var/lib/clanwright-app-exports/vaultwarden/pending";
    assert builtins.all (
      unit:
      unit.StateDirectory != ""
      && unit.RuntimeDirectory != ""
      && unit.ExecStartPre != ""
      && unit.ExecStartPost != ""
      && unit.ExecStopPost != ""
    ) (builtins.attrValues report.exported.units);
    assert report.exported.recovery == report.both.recovery;
    assert
      report.exported.caddyHosts == report.both.caddyHosts
      && report.exported.claims == report.both.claims;
    assert report.exported.failedAssertions == [ ];
    assert report.retainedExported.services == [ ] && report.retainedExported.timers == [ ];
    assert report.retainedExported.state == report.exported.state;
    assert report.retainedExported.builds == [ ] && report.retainedExported.recovery == { };
    assert report.retainedExported.caddyHosts == [ ] && report.retainedExported.claims == { };
    assert report.retainedExported.failedAssertions == [ ];
    assert
      report.withRestic.names == [
        "livesync-a"
        "livesync-b"
        "vaultwarden-a"
        "vaultwarden-b"
      ];
    assert report.withRestic.timers == [ ];
    assert builtins.all (
      name:
      let
        job = report.withRestic.jobs.${name};
      in
      job.timerConfig == null
      && !job.createWrapper
      && job.paths == [ "/var/cache/restic-backups-${name}/apps-input" ]
      && job.cacheDir == "/var/cache/restic-backups-${name}/cache"
      && lib.hasInfix "/bin/prepare-reader --max-age 86400 " job.prepare
      && lib.hasInfix "rm -rf --" job.cleanup
    ) report.withRestic.names;
    assert builtins.all (
      unit:
      unit.TimeoutStartSec == "2h" && unit.TimeoutStopSec == "2min" && unit.KillMode == "control-group"
    ) (builtins.attrValues report.withRestic.services);
    assert report.withRestic.failedAssertions == [ ];
    assert builtins.any (lib.hasInfix "100.64.0.10") report.conflicts.trust;
    assert !report.conflicts.sameDomain;
    assert report.existingNetwork.instances == report.both.instances;
    assert report.existingNetwork.recovery == report.both.recovery;
    assert report.existingNetwork.firewallSettingsPreserved;
    assert report.existingNetwork.failedAssertions == [ ];
    assert builtins.length report.coreOnly.instances == 3;
    assert report.coreOnly.failedAssertions == [ ];
    assert builtins.length report.threeMachines.instances == 13;
    assert builtins.all (messages: messages == [ ]) (
      builtins.attrValues report.threeMachines.failedAssertions
    );
    assert builtins.any (lib.hasInfix "effective Network certificate email")
      report.certificateConflict.failedAssertions;
    assert !report.certificateConflict.missingCoreEmail;
    assert
      report.rejected == {
        missingInstallation = false;
        missingPrivate = false;
        sameListeners = false;
        publicWildcard = false;
        publicInvalidOctet = false;
        privateWildcard = false;
        privateInvalidOctet = false;
        privateIPv6 = false;
      };
    assert report.defaults.obsidianSecret && report.defaults.vaultwardenSecret;
    assert report.defaults.couchdbVersion == "3.5.2";
    assert report.defaults.postgresVersion == "18.6";
    assert report.defaults.vaultwardenVersion == "1.37.3";
    assert report.defaults.vaultwardenPackageMatchesExport;
    assert report.defaults.couchdbState == [ "/var/lib/couchdb" ];
    assert report.defaults.obsidianAccessLog == "/var/log/caddy/obsidian-access.log";
    assert report.defaults.vaultwardenState == [ "/var/lib/vaultwarden" ];
    assert report.defaults.vaultwardenDbState == [ "/var/backup/postgres/vaultwarden" ];
    assert builtins.elem "vaultwarden.service" report.defaults.vaultwardenRestoreOrder;
    assert builtins.elem "postgresql.service" report.defaults.vaultwardenUnitAfter;
    assert builtins.elem "postgresql.service" report.defaults.vaultwardenUnitRequires;
    assert report.defaults.vaultwardenDbBackend == "postgresql";
    assert report.defaults.vaultwardenDatabaseUrl == "postgresql:///vaultwarden?host=/run/postgresql";
    assert report.defaults.vaultwardenDatabase.lifecycle == "enabled";
    assert report.defaults.vaultwardenDatabase.user == "vaultwarden";
    assert report.defaults.vaultwardenDatabase.restoreStopUnits == [ "vaultwarden.service" ];
    assert report.defaults.vaultwardenPublicAdmin404 && report.defaults.vaultwardenPrivateGuard;
    assert report.defaults.caddyPackageMatchesNetwork;
    true;
in
pkgs.runCommand "clanwright-apps-contract" { } ''
  test ${if check then "true" else "false"}
  ${lib.concatMapStringsSep "\n" (unit: ''
    test -x ${lib.escapeShellArg unit.captureCommand}
    test -x ${lib.escapeShellArg unit.validateCommand}
  '') (builtins.attrValues report.both.recovery)}
  test -x ${report.exported.packages.livesync}/bin/prepare-reader
  test -x ${report.exported.packages.livesync}/bin/validate
  test -x ${report.exported.packages.vaultwarden}/bin/prepare-reader
  test -x ${report.exported.packages.vaultwarden}/bin/validate
  cat > $out <<'REPORT'
  ${builtins.toJSON report}
  REPORT
''
