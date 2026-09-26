# Import once in the consumer Clan configuration. The consumer binds the
# public inputs named `apps` and `network`; no per-app dependency wiring is needed.
{ config, lib, ... }:
let
  inherit (lib)
    mkIf
    mkMerge
    mkOption
    types
    ;
  cfg = config.clanwright.apps;
  lifecycleType = types.enum [
    "enabled"
    "disabled-retained"
  ];
  privateType = types.submodule {
    options = {
      destinationIPv4 = mkOption {
        type = types.str;
        description = "Private IPv4 listener destination.";
      };
      trustedInterfaces = mkOption {
        type = types.listOf types.str;
        description = "Ingress interfaces trusted by Network for this destination.";
      };
    };
  };
  installationType = types.submodule {
    options = {
      publicIPv4 = mkOption {
        type = types.str;
        description = "Public IPv4 listener destination.";
      };
      certificateEmail = mkOption {
        type = types.str;
        description = "ACME account email for the shared Network certificates instance.";
      };
      privateIngress = mkOption {
        type = types.nullOr privateType;
        default = null;
        description = "Shared private IPv4 destination and trusted interfaces; required by active Vaultwarden.";
      };
    };
  };
  obsidianType = types.submodule {
    options = {
      domain = mkOption {
        type = types.str;
        description = "Public Obsidian LiveSync domain.";
      };
      adminConfigSecretName = mkOption {
        type = types.str;
        default = "livesync-couchdb-admin-ini";
        description = "Existing SOPS administrator INI secret name.";
      };
      lifecycle = mkOption {
        type = lifecycleType;
        default = "enabled";
      };
    };
  };
  vaultwardenType = types.submodule {
    options = {
      domain = mkOption {
        type = types.str;
        description = "Public Vaultwarden domain.";
      };
      adminTokenSecretName = mkOption {
        type = types.str;
        default = "vaultwarden-admin-token";
        description = "Existing SOPS admin token secret name.";
      };
      lifecycle = mkOption {
        type = lifecycleType;
        default = "enabled";
      };
      registration.open = mkOption {
        type = types.bool;
        default = false;
      };
      fail2ban.ignoreIPs = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
      logLevel = mkOption {
        type = types.enum [
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
  machineType = types.submodule {
    options = {
      installation = mkOption {
        type = types.nullOr installationType;
        default = null;
        description = "Common active app installation context. Retained-only selections need no context.";
      };
      obsidian = mkOption {
        type = types.nullOr obsidianType;
        default = null;
      };
      vaultwarden = mkOption {
        type = types.nullOr vaultwardenType;
        default = null;
      };
    };
  };
  networkInstance = name: role: machine: settings: {
    module = {
      input = "network";
      name = "@clanwright/${name}";
    };
    roles.${role}.machines.${machine} = lib.optionalAttrs (settings != null) { inherit settings; };
  };
  appInstance = name: role: machine: settings: {
    module = {
      input = "apps";
      name = "@clanwright/apps-${name}";
    };
    roles.${role}.machines.${machine} = { inherit settings; };
  };
  certName = domain: lib.replaceStrings [ "." ] [ "-" ] domain;
  requireInstallation =
    machine: installation:
    if installation == null then
      throw "Apps ${machine}: active application requires installation.publicIPv4 and installation.certificateEmail"
    else
      installation;
  requirePrivate =
    machine: installation:
    if installation.privateIngress == null then
      throw "Apps ${machine}: active Vaultwarden requires installation.privateIngress"
    else
      installation.privateIngress;
  requireDistinct =
    machine: installation: private:
    if installation.publicIPv4 == private.destinationIPv4 then
      throw "Apps ${machine}: Vaultwarden publicIPv4 and privateIngress.destinationIPv4 must differ"
    else
      private;
  requireIPv4 =
    machine: label: address:
    let
      octet = "(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])";
    in
    if
      builtins.match "${octet}[.]${octet}[.]${octet}[.]${octet}" address == null
      || builtins.elem address [
        "0.0.0.0"
        "255.255.255.255"
      ]
    then
      throw "Apps ${machine}: ${label} must be a usable explicit IPv4 address"
    else
      address;
  instancesFor =
    machine: selection:
    let
      inherit (selection) obsidian vaultwarden;
      obsidianActive = obsidian != null && obsidian.lifecycle == "enabled";
      vaultwardenActive = vaultwarden != null && vaultwarden.lifecycle == "enabled";
      anyActive = obsidianActive || vaultwardenActive;
      installation = if anyActive then requireInstallation machine selection.installation else null;
      publicIPv4 =
        if anyActive then requireIPv4 machine "installation.publicIPv4" installation.publicIPv4 else null;
      private =
        if vaultwardenActive then
          requireDistinct machine installation (requirePrivate machine installation)
        else
          null;
      tailnetIPv4 =
        if vaultwardenActive then
          requireIPv4 machine "installation.privateIngress.destinationIPv4" private.destinationIPv4
        else
          null;
    in
    mkMerge [
      (mkIf anyActive {
        "${machine}--network-certificates" = networkInstance "network-certificates" "server" machine (
          lib.mkDefault {
            email = installation.certificateEmail;
          }
        );
        "${machine}--network-caddy" = networkInstance "network-caddy" "ingress" machine null;
        "${machine}--network-firewall" = networkInstance "network-firewall" "host" machine null;
      })
      (mkIf (obsidian != null) {
        "${machine}--app-livesync-couchdb" = appInstance "livesync-couchdb" "server" machine {
          inherit (obsidian) domain adminConfigSecretName lifecycle;
          acme.certName = if obsidianActive then certName obsidian.domain else null;
          ingress.publicIPv4 = if obsidianActive then publicIPv4 else null;
        };
      })
      (mkIf (vaultwarden != null) {
        "${machine}--app-vaultwarden" = appInstance "vaultwarden" "app" machine {
          inherit (vaultwarden)
            domain
            adminTokenSecretName
            lifecycle
            registration
            fail2ban
            logLevel
            ;
          acme.certName = if vaultwardenActive then certName vaultwarden.domain else null;
          ingress = {
            publicIPv4 = if vaultwardenActive then publicIPv4 else null;
            inherit tailnetIPv4;
            trustedInterfaces = if vaultwardenActive then private.trustedInterfaces else [ ];
          };
        };
      })
    ];
in
{
  options.clanwright.apps.machines = mkOption {
    type = types.attrsOf machineType;
    default = { };
    description = "Per-machine Obsidian and Vaultwarden intent; null withdraws an app, disabled-retained preserves its state.";
  };
  config.inventory.instances = mkMerge (lib.mapAttrsToList instancesFor cfg.machines);
  config.machines = mkMerge (
    lib.mapAttrsToList (
      machine: selection:
      let
        active =
          (selection.obsidian != null && selection.obsidian.lifecycle == "enabled")
          || (selection.vaultwarden != null && selection.vaultwarden.lifecycle == "enabled");
      in
      mkIf active {
        ${machine}.imports = [
          ({ config, ... }: {
            assertions = [
              {
                assertion =
                  selection.installation.certificateEmail != ""
                  && config.security.acme.defaults.email == selection.installation.certificateEmail;
                message = "Apps ${machine}: effective Network certificate email must match installation.certificateEmail";
              }
            ];
          })
        ];
      }
    ) cfg.machines
  );
}
