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
  report = {
    none = {
      instances = instances empty;
    };
    obsidian = {
      instances = instances onlyObsidian;
      serviceName = onlyObsidian.clan.config.inventory.instances."fixture--app-obsidian".module.name;
      couchdb = onlyObsidian.config.services.couchdb.enable;
      postgresql = onlyObsidian.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames onlyObsidian.config.services.caddy.virtualHosts;
      claims = onlyObsidian.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed onlyObsidian;
    };
    vaultwarden = {
      instances = instances onlyVaultwarden;
      couchdb = onlyVaultwarden.config.services.couchdb.enable;
      postgresql = onlyVaultwarden.config.services.postgresql.enable;
      caddyHosts = builtins.attrNames onlyVaultwarden.config.services.caddy.virtualHosts;
      claims = onlyVaultwarden.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed onlyVaultwarden;
    };
    both = {
      instances = instances both;
      caddyHosts = builtins.attrNames both.config.services.caddy.virtualHosts;
      claims = both.config.networkCore.firewall.privateIngressClaims or { };
      failedAssertions = failed both;
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
    assert report.obsidian.failedAssertions == [ ];
    assert report.vaultwarden.failedAssertions == [ ];
    assert report.both.failedAssertions == [ ];
    assert report.retained.failedAssertions == [ ];
    assert builtins.length report.mixed.instances == 5;
    assert !report.mixed.couchdb && report.mixed.postgresql;
    assert report.mixed.caddyHosts == [ "fixture--app-vaultwarden" ];
    assert report.mixed.failedAssertions == [ ];
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
  cat > $out <<'REPORT'
  ${builtins.toJSON report}
  REPORT
''
