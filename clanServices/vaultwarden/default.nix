{
  appsPkgsFor ? (_system: throw "vaultwarden requires an explicit appsPkgsFor dependency"),
  lib,
  postgresqlModule,
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
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            description = "Public domain for Vaultwarden.";
          };

          acme.certName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "ACME certificate profile name used by Caddy.";
          };

          ingress = {
            publicIPv4 = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Public IPv4 address where Caddy accepts Vaultwarden traffic.";
            };
            tailnetIPv4 = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Tailnet IPv4 address where Caddy serves Vaultwarden admin paths.";
            };
            trustedInterfaces = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Interfaces trusted for the private ingress destination.";
            };
          };

          registration.open = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether public signup is enabled.";
          };

          fail2ban.ignoreIPs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Addresses exempted from the Vaultwarden authentication jail.";
          };

          adminTokenSecretName = lib.mkOption {
            type = lib.types.str;
            default = "vaultwarden-admin-token";
            description = "SOPS secret name that provides ADMIN_TOKEN via environment file.";
          };

          lifecycle = lib.mkOption {
            type = lib.types.enum [
              "enabled"
              "disabled-retained"
            ];
            default = "enabled";
            description = "Whether Vaultwarden runtime owners are active or retained for recovery.";
          };

          database = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "vaultwarden";
            };
            user = lib.mkOption {
              type = lib.types.str;
              default = "vaultwarden";
            };
          };

          logLevel = lib.mkOption {
            type = lib.types.enum [
              "trace"
              "debug"
              "info"
              "warn"
              "error"
              "off"
            ];
            default = "warn";
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
            system =
              if pkgs ? stdenv && pkgs.stdenv ? hostPlatform && pkgs.stdenv.hostPlatform ? system then
                pkgs.stdenv.hostPlatform.system
              else
                builtins.currentSystem;
            appsPkgs = appsPkgsFor system;
            vaultwardenHost = "127.0.0.1";
            vaultwardenPort = 8222;
            vaultwardenBackend = "${vaultwardenHost}:${toString vaultwardenPort}";
            active = settings.lifecycle == "enabled";
            publicIPv4 =
              if settings.ingress.publicIPv4 == null then
                throw "Apps Vaultwarden: active installation requires publicIPv4"
              else
                settings.ingress.publicIPv4;
            tailnetIPv4 =
              if settings.ingress.tailnetIPv4 == null then
                throw "Apps Vaultwarden: active installation requires privateIngress.destinationIPv4"
              else
                settings.ingress.tailnetIPv4;
            certName =
              if settings.acme.certName == null then
                throw "Apps Vaultwarden: active installation requires certificate context"
              else
                settings.acme.certName;
            accessLogPath = "/var/log/caddy/vaultwarden-access.log";
            authFailRegex = ''^.*"remote_ip":"<HOST>".*"method":"(GET|POST)".*"uri":"\/(identity\/(connect\/token|accounts\/prelogin|accounts\/register)|admin).*"status":(401|429).*$'';
            caddyRoute = ''
              @tailnetRoot {
                expression `{http.request.local.host} == "${tailnetIPv4}"`
                path /
              }
              redir @tailnetRoot /admin

              @tailnetAdmin {
                expression `{http.request.local.host} == "${tailnetIPv4}"`
                path /admin /admin/*
              }
              route @tailnetAdmin {
                rate_limit {
                  zone vaultwarden_auth_admin {
                    key {remote_host}
                    events 14
                    window 1m
                  }
                }
                reverse_proxy ${vaultwardenBackend}
              }

              @tailnetStatic {
                expression `{http.request.local.host} == "${tailnetIPv4}"`
                path /vw_static*
              }
              reverse_proxy @tailnetStatic ${vaultwardenBackend}

              @publicAdminPaths {
                expression `{http.request.local.host} != "${tailnetIPv4}"`
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
                reverse_proxy ${vaultwardenBackend}
              }

              reverse_proxy ${vaultwardenBackend}
            '';
          in
          lib.recursiveUpdate
            {
              imports = [ postgresqlModule ];

              sops.secrets."${settings.adminTokenSecretName}" = {
                owner = "root";
                group = "root";
                mode = "0400";
                restartUnits = lib.optional active "vaultwarden.service";
              };

              clan.core.state.vaultwarden-app.folders = [ "/var/lib/vaultwarden" ];

              services.clanwright.primitives.postgresql.databases."${settings.database.name}" = {
                inherit (settings) lifecycle;
                inherit (settings.database) user;
                stateName = "${settings.database.name}-db";
                restoreStopUnits = [ "vaultwarden.service" ];
              };
            }
            (
              lib.optionalAttrs active {
                networkCore = {
                  caddy.fragments.${instanceName} = {
                    hostName = settings.domain;
                    listenAddresses = [
                      publicIPv4
                      tailnetIPv4
                    ];
                    useACMEHost = certName;
                    afterUnits = [
                      "tailscaled.service"
                      "tailscaled-autoconnect.service"
                    ];
                    wantsUnits = [
                      "tailscaled.service"
                      "tailscaled-autoconnect.service"
                    ];
                    logFile = accessLogPath;
                    extraConfig = caddyRoute;
                  };
                  acme.certificateClaims.${certName} = {
                    inherit (settings) domain;
                    extraDomainNames = [ ];
                  };
                  firewall.privateIngressClaims.${instanceName} = {
                    destinationIPv4 = tailnetIPv4;
                    trustedInterfaces = settings.ingress.trustedInterfaces;
                  };
                };

                services.vaultwarden = {
                  enable = true;
                  dbBackend = "postgresql";
                  configureNginx = false;
                  package = appsPkgs.vaultwarden;
                  environmentFile = [ config.sops.secrets."${settings.adminTokenSecretName}".path ];
                  config = {
                    DOMAIN = "https://${settings.domain}";
                    DATABASE_URL = "postgresql:///${settings.database.name}?host=/run/postgresql";
                    SIGNUPS_ALLOWED = settings.registration.open;
                    INVITATIONS_ALLOWED = false;
                    SENDS_ALLOWED = false;
                    EMERGENCY_ACCESS_ALLOWED = false;
                    EMAIL_CHANGE_ALLOWED = false;
                    SHOW_PASSWORD_HINT = false;
                    WEBSOCKET_ENABLED = true;
                    ROCKET_ADDRESS = vaultwardenHost;
                    ROCKET_PORT = vaultwardenPort;
                    ROCKET_LOG = settings.logLevel;
                  };
                };

                services.fail2ban = {
                  enable = true;
                  jails.vaultwarden-auth = {
                    filter.Definition.failregex = authFailRegex;
                    settings = {
                      enabled = true;
                      backend = "auto";
                      logpath = accessLogPath;
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
                networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

                systemd.services.vaultwarden = {
                  after = [ "postgresql.service" ];
                  requires = [ "postgresql.service" ];
                };
              }
            );
      };
  };
}
