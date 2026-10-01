{
  couchdbModule,
  couchdbErlangFor,
  lib,
  recoveryToolsFor,
  ...
}:
{
  _class = "clan.service";
  manifest = {
    name = "@clanwright/apps-obsidian";
    description = "CouchDB backend for Self-hosted LiveSync";
    readme = builtins.readFile ./README.md;
  };

  roles.server = {
    description = "Loopback-only CouchDB with restricted public Caddy ingress";
    interface =
      { lib, ... }:
      {
        options =
          (import ../../modules/app-options.nix {
            inherit lib;
            app = "obsidian";
          })
          // {
            certificateEmail = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "ACME account email for this app certificate.";
            };
            ingress.publicIPv4 = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Public IPv4 address where Caddy accepts app traffic.";
            };
          };
      };

    perInstance =
      {
        instanceName ? "app-obsidian",
        settings,
        ...
      }:
      {
        nixosModule =
          { config, pkgs, ... }:
          let
            recoveryTools = recoveryToolsFor pkgs;
            active = settings.lifecycle == "enabled";
            exportEnabled = settings.export.enable;
            producer = import ../../recovery/livesync.nix {
              inherit
                lib
                pkgs
                config
                ;
              tools = recoveryTools;
              erlang = couchdbErlangFor pkgs.stdenv.hostPlatform.system;
            };
            exportFactory = import ../../recovery/export.nix {
              inherit lib pkgs producer;
              id = "livesync";
            };
            publicIPv4 =
              if settings.ingress.publicIPv4 == null then
                throw "Apps Obsidian: active installation requires publicIPv4"
              else
                settings.ingress.publicIPv4;
            certificateId = if settings.certificateId == null then settings.domain else settings.certificateId;
            certificateEmail =
              if settings.certificateEmail == null || settings.certificateEmail == "" then
                throw "Apps: active installation requires certificateEmail"
              else
                settings.certificateEmail;
            liveSyncCaddyRoute = ''
              route {
                @obsidianPaths path / /_session /obsidian /obsidian/*
                handle @obsidianPaths {
                  reverse_proxy 127.0.0.1:5984
                }
                handle {
                  respond 404
                }
              }
            '';
          in
          lib.recursiveUpdate
            {
              imports = [
                couchdbModule
              ];

              services.clanwright.primitives.couchdb = {
                enable = true;
                inherit (settings) lifecycle adminConfigSecretName;
                stateName = "obsidian";
                extraConfig = {
                  couchdb = {
                    single_node = true;
                    max_document_size = 50000000;
                  };
                  chttpd = {
                    enable_cors = true;
                    require_valid_user = true;
                    max_http_request_size = 4294967296;
                  };
                  cors = {
                    credentials = true;
                    origins = "app://obsidian.md,capacitor://localhost,http://localhost";
                  };
                  httpd.WWW-Authenticate = ''Basic realm="couchdb"'';
                  log.level = "warning";
                };
              };
            }
            (
              lib.recursiveUpdate
                (lib.optionalAttrs exportEnabled {
                  clan.core.state.apps-export-livesync.folders = [ "/var/lib/clanwright-app-exports/livesync" ];
                })
                (
                  lib.recursiveUpdate
                    (lib.optionalAttrs active {
                      # A withdrawn exporter must not bypass its retained uncertainty
                      # barrier when the application itself remains enabled.
                      systemd.services.couchdb.unitConfig.ConditionPathExists = exportFactory.appUnitCondition;
                      security.acme.certs.${certificateId} = {
                        inherit (settings) domain;
                        email = certificateEmail;
                        group = "acme";
                      };
                      services.caddy.virtualHosts.${settings.domain} = {
                        owner = "apps:${instanceName}";
                        listenAddresses = [ publicIPv4 ];
                        useACMEHost = certificateId;
                        extraConfig = lib.mkOrder 2000 liveSyncCaddyRoute;
                      };

                      networking.firewall.allowedTCPPorts = [ 443 ];
                    })
                    (
                      lib.optionalAttrs (active && exportEnabled) {
                        system.build.appsLiveSyncExport = exportFactory.package;
                        systemd.services.apps-export-livesync = {
                          description = "Capture a private LiveSync export";
                          serviceConfig = exportFactory.serviceConfig;
                        };
                      }
                    )
                )
            );
      };
  };
}
