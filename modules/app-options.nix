{ lib, app }:
let
  inherit (lib) mkOption types;
in
{
  domain = mkOption {
    type = types.str;
    description = "Public ${app} domain.";
  };
  certificateId = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Existing physical ACME certificate ID; null uses the canonical app domain.";
  };
  lifecycle = mkOption {
    type = types.enum [
      "enabled"
      "disabled-retained"
    ];
    default = "enabled";
    description = "Whether app runtime owners are active or retained for recovery.";
  };
  export.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Provide a manually callable native ${app} export.";
  };
}
// (
  if app == "obsidian" then
    {
      adminConfigSecretName = mkOption {
        type = types.str;
        default = "obsidian-admin-ini";
        description = "Existing SOPS administrator INI secret name.";
      };
    }
  else
    {
      adminTokenSecretName = mkOption {
        type = types.str;
        default = "vaultwarden-admin-token";
        description = "Existing SOPS admin token environment-file secret name.";
      };
      registration.open = mkOption {
        type = types.bool;
        default = false;
        description = "Whether public signup is enabled.";
      };
      fail2ban.ignoreIPs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Addresses exempted from the Vaultwarden authentication jail.";
      };
      logLevel = mkOption {
        type = types.enum [
          "trace"
          "debug"
          "info"
          "warn"
          "error"
        ];
        default = "warn";
      };
    }
)
