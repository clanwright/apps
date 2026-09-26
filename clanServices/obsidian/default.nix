{ couchdbModule, lib, ... }:
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
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            description = "Public LiveSync domain.";
          };

          acme.certName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Existing ACME certificate profile used by Caddy.";
          };

          ingress.publicIPv4 = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Public IPv4 address where Caddy accepts LiveSync traffic.";
          };

          adminConfigSecretName = lib.mkOption {
            type = lib.types.str;
            default = "obsidian-admin-ini";
            description = "SOPS secret name containing the CouchDB administrator INI fragment.";
          };

          lifecycle = lib.mkOption {
            type = lib.types.enum [
              "enabled"
              "disabled-retained"
            ];
            default = "enabled";
            description = "Whether LiveSync runtime owners are active or retained for recovery.";
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
          _:
          let
            active = settings.lifecycle == "enabled";
            publicIPv4 =
              if settings.ingress.publicIPv4 == null then
                throw "Apps Obsidian: active installation requires publicIPv4"
              else
                settings.ingress.publicIPv4;
            certName =
              if settings.acme.certName == null then
                throw "Apps Obsidian: active installation requires certificate context"
              else
                settings.acme.certName;
            liveSyncCaddyRoute = ''
              @obsidianPaths path / /_session /obsidian /obsidian/*
              handle @obsidianPaths {
                reverse_proxy 127.0.0.1:5984
              }
              handle {
                respond 404
              }
            '';
          in
          {
            imports = [ couchdbModule ];

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
          // lib.optionalAttrs active {
            networkCore = {
              caddy.fragments.${instanceName} = {
                hostName = settings.domain;
                listenAddresses = [ publicIPv4 ];
                useACMEHost = certName;
                logFile = "/var/log/caddy/obsidian-access.log";
                extraConfig = liveSyncCaddyRoute;
              };
              acme.certificateClaims.${certName} = {
                inherit (settings) domain;
                extraDomainNames = [ ];
              };
            };

            networking.firewall.allowedTCPPorts = [ 443 ];
          };
      };
  };
}
