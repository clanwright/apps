{
  self,
  clan-core,
  network,
  apps-nixpkgs,
  system ? "x86_64-linux",
}:
let
  lib = clan-core.inputs.nixpkgs.lib;
  pkgs = clan-core.inputs.nixpkgs.legacyPackages.${system};
  context = {
    publicIPv4 = "192.0.2.10";
    certificateEmail = "fixture@example.invalid";
    privateIngress = {
      destinationIPv4 = "100.64.0.10";
      trustedInterfaces = [ "tailscale0" ];
    };
  };
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
        clanwright.apps.machines.fixture = {
          installation = context;
          obsidian = {
            domain = "obsidian.example.invalid";
            export.enable = true;
          };
          vaultwarden = {
            domain = "vaultwarden.example.invalid";
            export.enable = true;
          };
        };
        machines.fixture = {
          nixpkgs.hostPlatform = "x86_64-linux";
          system.stateVersion = "26.11";
          sops.defaultSopsFile = builtins.toFile "apps-export-fixture-sops.yaml" "sops:\n  age: []\n";
          sops.age.keyFile = "/run/fixture/age-key";
        };
        inventory = {
          meta.name = "apps-export-runtime";
          machines.fixture = { };
        };
      }
    ];
  };
  test = pkgs.testers.runNixOSTest {
    name = "apps-export-runtime";
    node.pkgsReadOnly = false;
    requiredFeatures = {
      kvm = false;
      nixos-test = false;
    };
    nodes.fixture.imports = [
      clan.config.nixosModules."clan-machine-fixture"
      ../examples/native-restic.nix
      (
        { config, pkgs, ... }:
        let
          example = import ../examples/native-restic.nix { inherit config lib pkgs; };
        in
        {
          # Full-system x86 QEMU guest on an ARM driver preserves Network's
          # supported architecture and avoids user-mode Erlang emulation.
          virtualisation.host.pkgs = lib.mkForce clan-core.inputs.nixpkgs.legacyPackages.${system};
          virtualisation.memorySize = 4096;
          virtualisation.diskSize = 8192;
          virtualisation.cores = 2;
          systemd.services = {
            caddy.enable = lib.mkForce false;
            sops-install-secrets.enable = lib.mkForce false;
            vaultwarden.wantedBy = lib.mkForce [ ];
            couchdb.wantedBy = lib.mkForce [ ];
            fixture-secrets = {
              before = [
                "vaultwarden.service"
                "couchdb.service"
              ];
              requiredBy = [
                "vaultwarden.service"
                "couchdb.service"
              ];
              serviceConfig.Type = "oneshot";
              serviceConfig.RemainAfterExit = true;
              script = ''
                install -d -m 0751 /run/secrets
                install -d -m 0700 /run/backup-config /run/backup-secrets
                printf 'ADMIN_TOKEN=disposable-fixture-token\n' > ${config.sops.secrets.vaultwarden-admin-token.path}
                printf '[admins]\nfixture = disposable-fixture-password\n' > ${config.sops.secrets.obsidian-admin-ini.path}
                chown ${config.sops.secrets.obsidian-admin-ini.owner}:${config.sops.secrets.obsidian-admin-ini.group} ${config.sops.secrets.obsidian-admin-ini.path}
                chmod 0400 /run/secrets/*
                for job in vaultwarden-a vaultwarden-b livesync-a livesync-b; do
                  printf '/var/lib/fixture-repositories/%s\n' "$job" > /run/backup-config/$job-repository
                  printf 'disposable-restic-password\n' > /run/backup-secrets/$job-password
                done
                chmod 0400 /run/backup-secrets/*
                mkdir -p /var/lib/fixture-repositories
              '';
            };
          }
          // lib.mapAttrs' (
            name: _:
            lib.nameValuePair "acme-${name}" {
              enable = lib.mkForce false;
            }
          ) config.security.acme.certs;
          services.fail2ban.enable = lib.mkForce false;
          sops.validateSopsFiles = false;
          system.activationScripts.setupSecrets.text = lib.mkForce "";
          clan.core.state.vaultwarden-db = {
            preBackupScript = lib.mkAfter ''
              if test -e /run/fixture-block-pre; then
                touch /run/fixture-pre-blocked
                while test -e /run/fixture-block-pre; do sleep 1; done
              fi
              test ! -e /run/fixture-fail-pre
            '';
            postBackupScript = lib.mkAfter ''
              test ! -e /run/fixture-fail-post
            '';
          };
          environment.etc."fixture-couchdb-directory".text = config.services.couchdb.databaseDir;
          environment.systemPackages = [
            pkgs.curl
            pkgs.jq
            pkgs.restic
          ];
          environment.etc."fixture-vaultwarden-export".source = config.system.build.appsVaultwardenExport;
          environment.etc."fixture-livesync-export".source = config.system.build.appsLiveSyncExport;
          services.restic.backups =
            lib.genAttrs
              [
                "vaultwarden-a"
                "vaultwarden-b"
                "livesync-a"
                "livesync-b"
              ]
              (name: {
                initialize = true;
                extraBackupArgs = lib.optionals (lib.hasPrefix "vaultwarden-" name) [
                  "--limit-upload"
                  "32"
                ];
                # Hold native jobs after their real reader preparation. This models
                # slow consumers without holding the Apps publication lock.
                backupPrepareCommand = lib.mkForce (
                  example.services.restic.backups.${name}.backupPrepareCommand
                  + ''
                    if test -e /run/fixture-hold-readers; then
                      touch /run/fixture-reader-${name}-ready
                      while test -e /run/fixture-hold-readers; do sleep 1; done
                    fi
                  ''
                );
              });
        }
      )
    ];
    testScript = builtins.readFile ./export-runtime/test.py;
  };
in
test.test
