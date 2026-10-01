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
  fixtureCertificates =
    selection:
    builtins.listToAttrs (
      lib.concatMap
        (
          app:
          let
            intent = selection.${app} or null;
          in
          lib.optional (intent != null && (intent.lifecycle or "enabled") == "enabled") {
            name = if (intent.certificateId or null) == null then intent.domain else intent.certificateId;
            value.dnsProvider = "timewebcloud";
          }
        )
        [
          "obsidian"
          "vaultwarden"
        ]
    );
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
        directory = "${self.outPath}/checks";
        imports = [
          self.clanModules.default
          {
            clanwright.apps.machines = selections;
            machines.fixture = {
              imports = [
                { security.acme.certs = fixtureCertificates (selections.fixture or { }); }
              ]
              ++ extraMachineImports;
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
  conflictingPostgresSocket =
    evaluate
      {
        fixture = {
          installation = context;
          inherit vaultwarden;
        };
      }
      { }
      [
        { services.postgresql.settings.unix_socket_directories = lib.mkForce "/tmp/other-postgresql"; }
      ];
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
  retained =
    evaluate
      {
        fixture = {
          obsidian = obsidian // {
            lifecycle = "disabled-retained";
          };
          vaultwarden = vaultwarden // {
            lifecycle = "disabled-retained";
          };
        };
      }
      { }
      [
        { services.postgresql.settings.unix_socket_directories = "/tmp/other-postgresql"; }
      ];
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
          networking.firewall.privateIngress.external = {
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
  coreInventory = {
    "fixture--network-certificates" = {
      module = {
        input = "network";
        name = "@clanwright/network-certificates";
      };
      roles.server.machines.fixture = { };
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
  } coreInventory [ ];
  coreOnly = evaluate { } coreInventory [ ];
  conflictingEmail = builtins.tryEval (
    builtins.deepSeq
      (evaluate
        {
          fixture = {
            installation = context;
            inherit obsidian;
          };
        }
        coreInventory
        [ { security.acme.certs."obsidian.example.invalid".email = "different@example.invalid"; } ]
      ).config.security.acme.certs."obsidian.example.invalid".email
      true
  );
  conflictingCertificateDomain = builtins.tryEval (
    builtins.deepSeq
      (evaluate
        {
          fixture = {
            installation = context;
            inherit obsidian;
          };
        }
        coreInventory
        [ { security.acme.certs."obsidian.example.invalid".domain = "different.example.invalid"; } ]
      ).config.security.acme.certs."obsidian.example.invalid".domain
      true
  );
  explicitCertificate = evaluate {
    fixture = {
      installation = context;
      obsidian = obsidian // {
        certificateId = "existing-obsidian-cert";
      };
    };
  } { } [ ];
  distinctDomains = evaluate {
    fixture = {
      installation = context;
      obsidian = obsidian // {
        domain = "obsidian.a-b.example.invalid";
      };
      vaultwarden = vaultwarden // {
        domain = "obsidian-a.b.example.invalid";
      };
    };
  } { } [ ];
  nativeExtension =
    evaluate
      {
        fixture = {
          installation = context;
          inherit obsidian;
        };
      }
      coreInventory
      [
        {
          services.caddy.virtualHosts."obsidian.example.invalid".extraConfig = lib.mkBefore ''
            route { respond /extension "consumer extension" }
          '';
          security.acme.certs."obsidian.example.invalid".reloadServices = [ "reader.service" ];
        }
      ];
  rejectedSetting =
    app: key: value:
    builtins.tryEval (
      builtins.deepSeq
        (evaluate
          {
            fixture = {
              installation = context;
              inherit obsidian vaultwarden;
            };
          }
          {
            "fixture--app-${app}".roles.${
              if app == "obsidian" then "server" else "app"
            }.machines.fixture.settings.${key} =
              value;
          }
          [ ]
        ).config.services.caddy.virtualHosts
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
        directory = "${self.outPath}/checks";
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
            machines = lib.genAttrs names (machine: {
              security.acme.certs = fixtureCertificates (
                {
                  alpha = { inherit obsidian; };
                  beta = { inherit vaultwarden; };
                  gamma = { inherit obsidian vaultwarden; };
                }
                .${machine}
              );
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
      .config.services.caddy.virtualHosts."obsidian.example.invalid".listenAddresses
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
      } { } [ ]).config.services.caddy.virtualHosts."vaultwarden.example.invalid".listenAddresses
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
      } { } [ ]).config.services.caddy.virtualHosts."vaultwarden.example.invalid".listenAddresses
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
        } { } [ ]).config.services.caddy.virtualHosts."obsidian.example.invalid".listenAddresses
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
        } { } [ ]).config.services.caddy.virtualHosts."vaultwarden.example.invalid".listenAddresses
        true
    );
  instances = value: builtins.attrNames value.clan.config.inventory.instances;
  failed = value: map (a: a.message) (builtins.filter (a: !a.assertion) value.config.assertions);
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
  report = {
    none = {
      instances = instances empty;
    };
    withdrawn = {
      instances = instances withdrawn;
      state = builtins.attrNames withdrawn.config.clan.core.state;
      secrets = builtins.attrNames withdrawn.config.sops.secrets;
      caddyHosts = builtins.attrNames withdrawn.config.services.caddy.virtualHosts;
      claims = withdrawn.config.networking.firewall.privateIngress or { };
      exportServices = exportServices withdrawn;
      exportState = exportState withdrawn;
    };
    obsidian = {
      instances = instances onlyObsidian;
      serviceName = onlyObsidian.clan.config.inventory.instances."fixture--app-obsidian".module.name;
      couchdb = onlyObsidian.config.services.couchdb.enable;
      postgresql = onlyObsidian.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames onlyObsidian.config.services.caddy.virtualHosts;
      claims = onlyObsidian.config.networking.firewall.privateIngress or { };
      failedAssertions = failed onlyObsidian;
      backupTimers = backupTimers onlyObsidian;
      backupServices = backupServices onlyObsidian;
    };
    vaultwarden = {
      instances = instances onlyVaultwarden;
      couchdb = onlyVaultwarden.config.services.couchdb.enable;
      postgresql = onlyVaultwarden.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames onlyVaultwarden.config.services.caddy.virtualHosts;
      claims = onlyVaultwarden.config.networking.firewall.privateIngress or { };
      failedAssertions = failed onlyVaultwarden;
      backupTimers = backupTimers onlyVaultwarden;
      backupServices = backupServices onlyVaultwarden;
    };
    both = {
      instances = instances both;
      caddyHosts = builtins.attrNames both.config.services.caddy.virtualHosts;
      claims = both.config.networking.firewall.privateIngress or { };
      failedAssertions = failed both;
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
            SendSIGKILL
            Restart
            Delegate
            RemainAfterExit
            StateDirectory
            StateDirectoryMode
            ExecStartPre
            ExecStart
            ExecStartPost
            ExecStopPost
            ;
        }
      );
      activationConditions = {
        livesync = exported.config.systemd.services.couchdb.unitConfig.ConditionPathExists;
        vaultwarden = exported.config.systemd.services.vaultwarden.unitConfig.ConditionPathExists;
      };
      packages = {
        livesync = exported.config.system.build.appsLiveSyncExport.outPath;
        vaultwarden = exported.config.system.build.appsVaultwardenExport.outPath;
      };
      caddyHosts = builtins.attrNames exported.config.services.caddy.virtualHosts;
      claims = exported.config.networking.firewall.privateIngress or { };
      failedAssertions = failed exported;
    };
    retainedExported = {
      services = exportServices retainedExported;
      timers = exportTimers retainedExported;
      state = exportState retainedExported;
      builds = exportBuilds retainedExported;
      caddyHosts = builtins.attrNames retainedExported.config.services.caddy.virtualHosts;
      claims = retainedExported.config.networking.firewall.privateIngress or { };
      failedAssertions = failed retainedExported;
    };
    retained = {
      instances = instances retained;
      couchdb = retained.config.services.couchdb.enable;
      postgresql = retained.config.services.postgresql.enable;
      postgresSocket = retained.config.services.postgresql.settings.unix_socket_directories;
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
      claims = retained.config.networking.firewall.privateIngress or { };
      failedAssertions = failed retained;
    };
    mixed = {
      instances = instances mixed;
      couchdb = mixed.config.services.couchdb.enable;
      postgresql = mixed.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames mixed.config.services.caddy.virtualHosts;
      failedAssertions = failed mixed;
    };
    conflicts = {
      trust = failed conflictingTrust;
      sameDomain = sameDomain.success;
    };
    existingNetwork = {
      instances = instances existingNetwork;
      certSettings =
        existingNetwork.clan.config.inventory.instances."fixture--network-certificates".roles.server.machines.fixture.settings;
      acmeEmail = existingNetwork.config.security.acme.certs."obsidian.example.invalid".email;
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
    certificates = {
      conflictingEmail = conflictingEmail.success;
      conflictingDomain = conflictingCertificateDomain.success;
      explicitIds = builtins.attrNames explicitCertificate.config.security.acme.certs;
      explicitVhost =
        explicitCertificate.config.services.caddy.virtualHosts."obsidian.example.invalid".useACMEHost;
      distinctIds = builtins.attrNames distinctDomains.config.security.acme.certs;
      defaultIds = builtins.attrNames both.config.security.acme.certs;
      obsidian = {
        inherit (both.config.security.acme.certs."obsidian.example.invalid")
          domain
          email
          group
          dnsProvider
          reloadServices
          ;
      };
      globalChallenges = {
        inherit (both.config.security.acme.defaults) dnsProvider webroot listenHTTP;
      };
      stockLego = builtins.elem both.clan.config.nixosConfigurations.fixture.pkgs.lego.outPath (
        map (
          package: package.outPath
        ) both.config.systemd.services."acme-order-renew-obsidian.example.invalid".path
      );
      nativeExtension = {
        route = nativeExtension.config.services.caddy.virtualHosts."obsidian.example.invalid".extraConfig;
        readers = nativeExtension.config.security.acme.certs."obsidian.example.invalid".reloadServices;
        failures = failed nativeExtension;
      };
    };
    postgresSocketConflict = failed conflictingPostgresSocket;
    rejected = {
      retiredDatabaseName = (rejectedSetting "vaultwarden" "database" { name = "other"; }).success;
      retiredDatabaseUser = (rejectedSetting "vaultwarden" "database" { user = "other"; }).success;
      retiredCertName = (rejectedSetting "obsidian" "acme" { certName = "old"; }).success;
      retiredTailnet = (rejectedSetting "vaultwarden" "ingress" { tailnetIPv4 = "100.64.0.10"; }).success;
      disabledAuthLogging = (rejectedSetting "vaultwarden" "logLevel" "off").success;
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
      obsidianCondition = onlyObsidian.config.systemd.services.couchdb.unitConfig.ConditionPathExists;
      vaultwardenCondition =
        onlyVaultwarden.config.systemd.services.vaultwarden.unitConfig.ConditionPathExists;
      couchdbVersion = onlyObsidian.config.services.couchdb.package.version;
      postgresVersion = onlyVaultwarden.config.services.postgresql.package.version;
      postgresSocket = onlyVaultwarden.config.services.postgresql.settings.unix_socket_directories;
      vaultwardenVersion = onlyVaultwarden.config.services.vaultwarden.package.version;
      vaultwardenPackageMatchesExport =
        onlyVaultwarden.config.services.vaultwarden.package.outPath
        == self.packages.x86_64-linux.vaultwarden.outPath;
      couchdbState = onlyObsidian.config.clan.core.state.obsidian.folders;
      vaultwardenAuthLogging = {
        inherit (onlyVaultwarden.config.services.vaultwarden.config)
          LOG_LEVEL
          EXTENDED_LOGGING
          LOG_TIMESTAMP_FORMAT
          IP_HEADER
          IP_HEADER_TRUSTED_PROXIES
          ;
      };
      vaultwardenAuthJail = onlyVaultwarden.config.services.fail2ban.jails.vaultwarden-auth;
      caddyAfter = onlyVaultwarden.config.systemd.services.caddy.after;
      caddyWants = onlyVaultwarden.config.systemd.services.caddy.wants;
      caddyOwner = onlyVaultwarden.config.services.caddy.virtualHosts."vaultwarden.example.invalid".owner;
      extraPrivatePorts = onlyVaultwarden.config.networking.firewall.interfaces;
      nativeGuards = onlyVaultwarden.config.networking.firewall.privateIngress;
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
          onlyVaultwarden.config.services.caddy.virtualHosts."vaultwarden.example.invalid".extraConfig;
      vaultwardenPrivateGuard = lib.hasInfix "100.64.0.10" onlyVaultwarden.config.networking.nftables.tables.network-edge-policy.content;
      caddyPackageMatchesNetwork =
        onlyVaultwarden.config.services.caddy.package.outPath
        == network.packages.x86_64-linux.caddy-custom.outPath;
    };
    revisions = {
      inherit (clan-core) rev;
      network = network.rev or null;
      primitives = primitives.rev or null;
      appsNixpkgs = apps-nixpkgs.rev;
    };
    networkSource = {
      path = network.outPath;
      narHash = network.narHash;
    };
    primitivesSource = {
      path = primitives.outPath;
      narHash = primitives.narHash;
    };
  };
  check =
    assert report.none.instances == [ ];
    assert report.withdrawn.instances == [ ];
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
    assert report.retained.postgresSocket == "/tmp/other-postgresql";
    assert report.retained.couchdbState == [ "/var/lib/couchdb" ];
    assert report.retained.vaultwardenState == [ "/var/lib/vaultwarden" ];
    assert report.retained.vaultwardenDbState == [ "/var/backup/postgres/vaultwarden" ];
    assert report.retained.obsidianSecret && report.retained.vaultwardenSecret;
    assert report.retained.vaultwardenSecretRestartUnits == [ ];
    assert report.retained.vaultwardenDatabaseLifecycle == "disabled-retained";
    assert report.retained.caddyHosts == [ ] && report.retained.claims == { };
    assert report.obsidian.failedAssertions == [ ];
    assert report.vaultwarden.failedAssertions == [ ];
    assert report.both.failedAssertions == [ ];
    assert report.retained.failedAssertions == [ ];
    assert builtins.length report.mixed.instances == 5;
    assert !report.mixed.couchdb && report.mixed.postgresql;
    assert report.mixed.caddyHosts == [ "vaultwarden.example.invalid" ];
    assert report.mixed.failedAssertions == [ ];
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
      && unit.TimeoutStopSec == "6min"
      && unit.KillMode == "control-group"
      && unit.SendSIGKILL
      && unit.Restart == "no"
      && !unit.Delegate
      && !unit.RemainAfterExit
      && unit.StateDirectoryMode == "0700"
    ) (builtins.attrValues report.exported.units);
    assert lib.hasSuffix "/bin/apps-export-livesync-capture"
      report.exported.units.apps-export-livesync.ExecStart;
    assert lib.hasSuffix "/bin/apps-export-vaultwarden-capture"
      report.exported.units.apps-export-vaultwarden.ExecStart;
    assert builtins.all (
      unit:
      unit.StateDirectory != ""
      && unit.ExecStartPre != ""
      && unit.ExecStartPost != ""
      && unit.ExecStopPost != ""
    ) (builtins.attrValues report.exported.units);
    assert
      report.exported.activationConditions.livesync
      == "!/var/lib/clanwright-app-exports/livesync/inhibit";
    assert
      report.exported.activationConditions.vaultwarden
      == "!/var/lib/clanwright-app-exports/vaultwarden/inhibit";
    assert
      report.exported.caddyHosts == report.both.caddyHosts
      && report.exported.claims == report.both.claims;
    assert report.exported.failedAssertions == [ ];
    assert report.retainedExported.services == [ ] && report.retainedExported.timers == [ ];
    assert report.retainedExported.state == report.exported.state;
    assert report.retainedExported.builds == [ ];
    assert report.retainedExported.caddyHosts == [ ] && report.retainedExported.claims == { };
    assert report.retainedExported.failedAssertions == [ ];
    assert builtins.any (lib.hasInfix "100.64.0.10") report.conflicts.trust;
    assert !report.conflicts.sameDomain;
    assert report.existingNetwork.instances == report.both.instances;
    assert report.existingNetwork.firewallSettingsPreserved;
    assert report.existingNetwork.failedAssertions == [ ];
    assert builtins.length report.coreOnly.instances == 3;
    assert report.coreOnly.failedAssertions == [ ];
    assert builtins.length report.threeMachines.instances == 13;
    assert builtins.all (messages: messages == [ ]) (
      builtins.attrValues report.threeMachines.failedAssertions
    );
    assert !report.certificates.conflictingEmail && !report.certificates.conflictingDomain;
    assert report.certificates.explicitIds == [ "existing-obsidian-cert" ];
    assert report.certificates.explicitVhost == "existing-obsidian-cert";
    assert
      report.certificates.distinctIds == [
        "obsidian-a.b.example.invalid"
        "obsidian.a-b.example.invalid"
      ];
    assert
      report.certificates.defaultIds == [
        "obsidian.example.invalid"
        "vaultwarden.example.invalid"
      ];
    assert report.certificates.obsidian.domain == "obsidian.example.invalid";
    assert report.certificates.obsidian.email == context.certificateEmail;
    assert report.certificates.obsidian.group == "acme";
    assert report.certificates.obsidian.dnsProvider == "timewebcloud";
    assert report.certificates.obsidian.reloadServices == [ "caddy.service" ];
    assert
      report.certificates.globalChallenges == {
        dnsProvider = null;
        webroot = null;
        listenHTTP = null;
      };
    assert report.certificates.stockLego;
    assert lib.hasInfix "consumer extension" report.certificates.nativeExtension.route;
    assert lib.hasInfix "@obsidianPaths" report.certificates.nativeExtension.route;
    assert lib.count (x: x == "caddy.service") report.certificates.nativeExtension.readers == 1;
    assert builtins.elem "reader.service" report.certificates.nativeExtension.readers;
    assert report.certificates.nativeExtension.failures == [ ];
    assert
      report.rejected == {
        retiredDatabaseName = false;
        retiredDatabaseUser = false;
        retiredCertName = false;
        retiredTailnet = false;
        disabledAuthLogging = false;
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
    assert report.defaults.obsidianCondition == "!/var/lib/clanwright-app-exports/livesync/inhibit";
    assert
      report.defaults.vaultwardenCondition == "!/var/lib/clanwright-app-exports/vaultwarden/inhibit";
    assert report.defaults.couchdbVersion == "3.5.2";
    assert report.defaults.postgresVersion == "18.6";
    assert report.defaults.postgresSocket == "/run/postgresql";
    assert builtins.elem "Apps Vaultwarden requires the native PostgreSQL socket at /run/postgresql"
      report.postgresSocketConflict;
    assert report.defaults.vaultwardenVersion == "1.37.3";
    assert report.defaults.vaultwardenPackageMatchesExport;
    assert report.defaults.couchdbState == [ "/var/lib/couchdb" ];
    assert
      report.defaults.vaultwardenAuthLogging == {
        LOG_LEVEL = "warn";
        EXTENDED_LOGGING = true;
        LOG_TIMESTAMP_FORMAT = "";
        IP_HEADER = "X-Real-IP";
        IP_HEADER_TRUSTED_PROXIES = "127.0.0.1";
      };
    assert report.defaults.vaultwardenAuthJail.settings.backend == "systemd";
    assert !(report.defaults.vaultwardenAuthJail.settings ? logpath);
    assert !(report.defaults.vaultwardenAuthJail.filter.Definition ? failregex);
    assert
      report.defaults.vaultwardenAuthJail.filter.INCLUDES.before == "common.conf\n vaultwarden.conf";
    assert report.defaults.caddyOwner == "apps:fixture--app-vaultwarden";
    assert !builtins.elem "tailscaled.service" report.defaults.caddyAfter;
    assert !builtins.elem "tailscaled-autoconnect.service" report.defaults.caddyWants;
    assert !(report.defaults.extraPrivatePorts ? tailscale0);
    assert report.defaults.nativeGuards."fixture--app-vaultwarden".destinationIPv4 == "100.64.0.10";
    assert report.defaults.vaultwardenState == [ "/var/lib/vaultwarden" ];
    assert report.defaults.vaultwardenDbState == [ "/var/backup/postgres/vaultwarden" ];
    assert builtins.elem "vaultwarden.service" report.defaults.vaultwardenRestoreOrder;
    assert builtins.elem "postgresql.service" report.defaults.vaultwardenUnitAfter;
    assert builtins.elem "postgresql.service" report.defaults.vaultwardenUnitRequires;
    assert report.defaults.vaultwardenDbBackend == "postgresql";
    assert
      report.defaults.vaultwardenDatabaseUrl
      == "postgresql:///vaultwarden?host=/run/postgresql&port=5432";
    assert report.defaults.vaultwardenDatabase.lifecycle == "enabled";
    assert report.defaults.vaultwardenDatabase.user == "vaultwarden";
    assert report.defaults.vaultwardenDatabase.restoreStopUnits == [ "vaultwarden.service" ];
    assert report.defaults.vaultwardenPublicAdmin404 && report.defaults.vaultwardenPrivateGuard;
    assert report.defaults.caddyPackageMatchesNetwork;
    true;
in
pkgs.runCommand "clanwright-apps-contract" { } ''
  test ${if check then "true" else "false"}
  test -x ${report.exported.packages.livesync}/bin/prepare-reader
  test -x ${report.exported.packages.livesync}/bin/validate
  test -x ${report.exported.packages.vaultwarden}/bin/prepare-reader
  test -x ${report.exported.packages.vaultwarden}/bin/validate
  cat > $out <<'REPORT'
  ${builtins.toJSON report}
  REPORT
''
