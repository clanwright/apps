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
          probe = pkgs.writeShellApplication {
            name = "fixture-validation-probe";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.curl
            ];
            text = ''
              evidence=$1
              trap 'printf "HTTP continuity probe failed\n" > "$evidence/failed"' ERR
              while test ! -e "$evidence/stop"; do
                curl -fsS --max-time 10 http://127.0.0.1:8222/alive >/dev/null
                curl -fsS --max-time 10 -u fixture:disposable-fixture-password http://127.0.0.1:5984/_up >/dev/null
                printf 'both applications reachable\n' >> "$evidence/samples"
                touch "$evidence/ready"
                sleep 0.2
              done
            '';
          };
          # Test-only harness: the unchanged Python loop still calls the real
          # public validator on each independently restored Restic directory.
          checkedExport =
            app: original:
            let
              validator = pkgs.writeShellApplication {
                name = "validate";
                excludeShellChecks = [ "SC2329" ]; # cleanup runs from the EXIT trap.
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.curl
                  pkgs.diffutils
                  pkgs.gnugrep
                  pkgs.jq
                  pkgs.systemd
                  pkgs.util-linux
                ];
                text = ''
                  test "$#" -eq 1
                  systemctl start fixture-validation-data
                  evidence=$(mktemp -d /var/tmp/fixture-validation-${app}.XXXXXXXX)
                  unit="''${evidence##*/}-probe"
                  cleanup() {
                    touch "$evidence/stop"
                    if ! systemctl stop "$unit"; then
                      # A successful transient probe can already be unloaded.
                      test "$(systemctl show "$unit" -p LoadState --value)" = not-found
                    fi
                  }
                  trap cleanup EXIT
                  snapshot() {
                    destination=$1
                    for service in vaultwarden couchdb postgresql; do
                      systemctl is-active --quiet "$service"
                      test "$(systemctl show "$service" -p MainPID --value)" -gt 0
                      test -n "$(systemctl show "$service" -p InvocationID --value)"
                    done
                    systemctl show vaultwarden couchdb postgresql -p Id -p InvocationID -p MainPID > "$destination.units"
                    curl -fsS --max-time 10 -u fixture:disposable-fixture-password http://127.0.0.1:5984/obsidian/leaf | jq -S . > "$destination.couchdb"
                    jq -e '.data == "fixture bytes"' "$destination.couchdb" >/dev/null
                    runuser -u postgres -- ${config.services.postgresql.package}/bin/psql -X -v ON_ERROR_STOP=1 -A -t -d vaultwarden -c 'SELECT data FROM apps_validation_fixture' > "$destination.postgresql"
                    grep -qx 'fixture bytes' "$destination.postgresql"
                    sha256sum /var/lib/vaultwarden/continuity-fixture > "$destination.files"
                  }
                  # Native captures restart the application before returning;
                  # establish HTTP readiness before the outage-sensitive sampler.
                  ready=0
                  for _ in $(seq 1 30); do
                    if curl -fsS --max-time 2 http://127.0.0.1:8222/alive >/dev/null && \
                       curl -fsS --max-time 2 -u fixture:disposable-fixture-password http://127.0.0.1:5984/_up >/dev/null; then
                      ready=1
                      break
                    fi
                    sleep 1
                  done
                  test "$ready" -eq 1
                  snapshot "$evidence/before"
                  systemd-run --unit="$unit" --service-type=exec \
                    --property=RuntimeMaxSec=950s --property=TimeoutStopSec=15s \
                    ${probe}/bin/fixture-validation-probe "$evidence"
                  for _ in $(seq 1 60); do
                    if test -e "$evidence/failed"; then
                      cat "$evidence/failed" >&2
                      journalctl -u "$unit" --no-pager >&2
                      exit 1
                    fi
                    if test -e "$evidence/ready"; then break; fi
                    sleep 1
                  done
                  test -e "$evidence/ready"
                  initial_samples=$(wc -l < "$evidence/samples")
                  ${original}/bin/validate "$1"
                  test "$(wc -l < "$evidence/samples")" -gt "$initial_samples"
                  snapshot "$evidence/after-success"
                  for kind in units couchdb postgresql files; do
                    cmp "$evidence/before.$kind" "$evidence/after-success.$kind"
                  done
                  # A rejected semantic input must also leave the live host intact.
                  mkdir "$evidence/incompatible"
                  cp -a "$1/." "$evidence/incompatible/"
                  printf 'incompatible-fixture-format\n' > "$evidence/incompatible/format-version"
                  if ${original}/bin/validate "$evidence/incompatible" > "$evidence/rejected.log" 2>&1; then
                    echo 'incompatible format unexpectedly validated' >&2
                    exit 1
                  fi
                  grep -F 'missing or unsupported format' "$evidence/rejected.log"
                  snapshot "$evidence/after-rejection"
                  for kind in units couchdb postgresql files; do
                    cmp "$evidence/before.$kind" "$evidence/after-rejection.$kind"
                  done
                  touch "$evidence/stop"
                  for _ in $(seq 1 30); do
                    state=$(systemctl show "$unit" -p ActiveState --value)
                    if test "$state" = inactive || test "$state" = failed; then break; fi
                    sleep 1
                  done
                  systemctl show "$unit" -p ActiveState -p Result
                  if test -e "$evidence/failed"; then
                    cat "$evidence/failed" >&2
                    journalctl -u "$unit" --no-pager >&2
                    exit 1
                  fi
                  test "$state" = inactive
                  test "$(systemctl show "$unit" -p Result --value)" = success
                  echo "${app}: live service identities and fixture data unchanged; HTTP samples: $(wc -l < "$evidence/samples"); evidence: $evidence"
                '';
              };
            in
            pkgs.runCommand "fixture-${app}-export" { } ''
              mkdir -p "$out/bin"
              ln -s ${original}/bin/prepare-reader "$out/bin/prepare-reader"
              ln -s ${validator}/bin/validate "$out/bin/validate"
            '';
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
            fixture-validation-data = {
              serviceConfig.Type = "oneshot";
              serviceConfig.RemainAfterExit = true;
              path = [
                pkgs.coreutils
                pkgs.util-linux
              ];
              script = ''
                runuser -u postgres -- ${config.services.postgresql.package}/bin/psql -X -v ON_ERROR_STOP=1 -d vaultwarden -c "CREATE TABLE apps_validation_fixture (data text); INSERT INTO apps_validation_fixture VALUES ('fixture bytes');"
                printf 'fixture bytes\n' > /var/lib/vaultwarden/continuity-fixture
              '';
            };
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
          environment.etc."fixture-vaultwarden-export".source =
            checkedExport "vaultwarden" config.system.build.appsVaultwardenExport;
          environment.etc."fixture-livesync-export".source =
            checkedExport "livesync" config.system.build.appsLiveSyncExport;
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
