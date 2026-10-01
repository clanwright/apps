{
  appsPkgsFor,
  lib,
  postgresqlModule,
  recoveryToolsFor,
  ...
}:
{
  _class = "clan.service";
  manifest = {
    name = "@clanwright/apps-vaultwarden";
    description = "Vaultwarden password manager service";
    readme = builtins.readFile ./README.md;
  };

  roles.app = {
    description = "Public Vaultwarden app";
    interface =
      { lib, ... }:
      {
        options =
          (import ../../modules/app-options.nix {
            inherit lib;
            app = "vaultwarden";
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
            ingress.privateIPv4 = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Private IPv4 address where Caddy serves Vaultwarden admin paths.";
            };
            ingress.trustedInterfaces = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Interfaces trusted for the private ingress destination.";
            };
          };
      };

    perInstance =
      {
        instanceName ? "app-vaultwarden",
        settings,
        ...
      }:
      {
        nixosModule =
          {
            config,
            pkgs,
            ...
          }:
          let
            system = pkgs.stdenv.hostPlatform.system;
            appsPkgs = appsPkgsFor system;
            recoveryTools = recoveryToolsFor pkgs;
            vaultwardenHost = "127.0.0.1";
            vaultwardenPort = 8222;
            vaultwardenBackend = "${vaultwardenHost}:${toString vaultwardenPort}";
            active = settings.lifecycle == "enabled";
            exportEnabled = settings.export.enable;
            producer = import ../../recovery/vaultwarden.nix {
              inherit
                lib
                pkgs
                config
                ;
              tools = recoveryTools;
            };
            exportFactory = import ../../recovery/export.nix {
              inherit lib pkgs producer;
              id = "vaultwarden";
            };
            publicIPv4 =
              if settings.ingress.publicIPv4 == null then
                throw "Apps Vaultwarden: active installation requires publicIPv4"
              else
                settings.ingress.publicIPv4;
            privateIPv4 =
              if settings.ingress.privateIPv4 == null then
                throw "Apps Vaultwarden: active installation requires privateIngress.destinationIPv4"
              else
                settings.ingress.privateIPv4;
            certificateId = if settings.certificateId == null then settings.domain else settings.certificateId;
            certificateEmail =
              if settings.certificateEmail == null || settings.certificateEmail == "" then
                throw "Apps: active installation requires certificateEmail"
              else
                settings.certificateEmail;
            caddyRoute = ''
              route {
                @privateRoot {
                  expression `{http.request.local.host} == "${privateIPv4}"`
                  path /
                }
                redir @privateRoot /admin

                @privateAdmin {
                  expression `{http.request.local.host} == "${privateIPv4}"`
                  path /admin /admin/*
                }
                route @privateAdmin {
                  rate_limit {
                    zone vaultwarden_auth_admin {
                      key {remote_host}
                      events 14
                      window 1m
                    }
                  }
                  reverse_proxy ${vaultwardenBackend} {
                    header_up X-Real-IP {remote_host}
                  }
                }

                @privateStatic {
                  expression `{http.request.local.host} == "${privateIPv4}"`
                  path /vw_static*
                }
                reverse_proxy @privateStatic ${vaultwardenBackend} {
                  header_up X-Real-IP {remote_host}
                }

                @publicAdminPaths {
                  expression `{http.request.local.host} != "${privateIPv4}"`
                  path /admin /admin/*
                }
                respond @publicAdminPaths 404

                @adminPaths path /admin /admin/*
                respond @adminPaths 404

                @vaultPaths path /vault /vault/*
                respond @vaultPaths 404

                @vaultwardenAuth path /identity/connect/token /identity/accounts/prelogin /identity/accounts/register
                route @vaultwardenAuth {
                  rate_limit {
                    zone vaultwarden_auth_public {
                      key {remote_host}
                      events 14
                      window 1m
                    }
                  }
                  reverse_proxy ${vaultwardenBackend} {
                    header_up X-Real-IP {remote_host}
                  }
                }

                reverse_proxy ${vaultwardenBackend} {
                    header_up X-Real-IP {remote_host}
                  }
              }
            '';
          in
          lib.recursiveUpdate
            {
              imports = [
                postgresqlModule
              ];

              sops.secrets."${settings.adminTokenSecretName}" = {
                owner = "root";
                group = "root";
                mode = "0400";
                restartUnits = lib.optional active "vaultwarden.service";
              };

              clan.core.state = {
                vaultwarden-app.folders = [ "/var/lib/vaultwarden" ];
              }
              // lib.optionalAttrs exportEnabled {
                apps-export-vaultwarden.folders = [ "/var/lib/clanwright-app-exports/vaultwarden" ];
              };

              services.clanwright.primitives.postgresql.databases.vaultwarden = {
                inherit (settings) lifecycle;
                user = "vaultwarden";
                stateName = "vaultwarden-db";
                restoreStopUnits = [ "vaultwarden.service" ];
              };
            }
            (
              lib.recursiveUpdate
                (lib.optionalAttrs active {
                  services.postgresql.settings.unix_socket_directories = "/run/postgresql";
                  assertions = [
                    {
                      assertion = config.services.postgresql.settings.unix_socket_directories == "/run/postgresql";
                      message = "Apps Vaultwarden requires the native PostgreSQL socket at /run/postgresql";
                    }
                  ];
                  security.acme.certs.${certificateId} = {
                    inherit (settings) domain;
                    email = certificateEmail;
                    group = "acme";
                  };
                  services.caddy.virtualHosts.${settings.domain} = {
                    owner = "apps:${instanceName}";
                    listenAddresses = [
                      publicIPv4
                      privateIPv4
                    ];
                    useACMEHost = certificateId;
                    extraConfig = lib.mkOrder 2000 caddyRoute;
                  };
                  networking.firewall.privateIngress.${instanceName} = {
                    destinationIPv4 = privateIPv4;
                    trustedInterfaces = settings.ingress.trustedInterfaces;
                  };

                  services.vaultwarden = {
                    enable = true;
                    dbBackend = "postgresql";
                    configureNginx = false;
                    package = appsPkgs.vaultwarden;
                    environmentFile = [ config.sops.secrets."${settings.adminTokenSecretName}".path ];
                    config = {
                      DOMAIN = "https://${settings.domain}";
                      DATABASE_URL = "postgresql:///vaultwarden?host=/run/postgresql&port=${toString config.services.postgresql.settings.port}";
                      SIGNUPS_ALLOWED = settings.registration.open;
                      INVITATIONS_ALLOWED = false;
                      SENDS_ALLOWED = false;
                      EMERGENCY_ACCESS_ALLOWED = false;
                      EMAIL_CHANGE_ALLOWED = false;
                      SHOW_PASSWORD_HINT = false;
                      WEBSOCKET_ENABLED = true;
                      ROCKET_ADDRESS = vaultwardenHost;
                      ROCKET_PORT = vaultwardenPort;
                      LOG_LEVEL = settings.logLevel;
                      EXTENDED_LOGGING = true;
                      LOG_TIMESTAMP_FORMAT = "";
                      IP_HEADER = "X-Real-IP";
                      IP_HEADER_TRUSTED_PROXIES = "127.0.0.1";
                    };
                  };

                  services.fail2ban = {
                    enable = true;
                    jails.vaultwarden-auth = {
                      filter = {
                        # INI continuation needs indentation after the newline.
                        INCLUDES.before = "common.conf\n vaultwarden.conf";
                        DEFAULT = {
                          _daemon = "vaultwarden";
                          logtype = "journal";
                        };
                        Definition = {
                          prefregex = "^%(__prefix_line)s<F-CONTENT>.+</F-CONTENT>$";
                          journalmatch = "_SYSTEMD_UNIT=vaultwarden.service";
                        };
                      };
                      settings = {
                        enabled = true;
                        backend = "systemd";
                        port = "http,https";
                        protocol = "tcp";
                        maxretry = 8;
                        findtime = "10m";
                        bantime = "1h";
                      }
                      // lib.optionalAttrs (settings.fail2ban.ignoreIPs != [ ]) {
                        ignoreip = lib.concatStringsSep " " settings.fail2ban.ignoreIPs;
                      };
                    };
                  };

                  networking.firewall.allowedTCPPorts = [ 443 ];

                  systemd.services.vaultwarden = {
                    after = [ "postgresql.service" ];
                    requires = [ "postgresql.service" ];
                    # Export withdrawal leaves a retained uncertainty barrier
                    # effective for every later automatic application start.
                    unitConfig.ConditionPathExists = exportFactory.appUnitCondition;
                  };
                })
                (
                  lib.optionalAttrs (active && exportEnabled) {
                    system.build.appsVaultwardenExport = exportFactory.package;
                    systemd.services.apps-export-vaultwarden = {
                      description = "Capture a private Vaultwarden export";
                      serviceConfig = exportFactory.serviceConfig;
                    };
                  }
                )
            );
      };
  };
}
