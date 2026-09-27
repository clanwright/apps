# Import into the consuming machine's NixOS configuration after enabling
# export.enable on both Apps recipe selections. This example is manual-only;
# the consumer provisions repository/password files and chooses all schedules.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  jobs = {
    vaultwarden-a = config.system.build.appsVaultwardenExport;
    vaultwarden-b = config.system.build.appsVaultwardenExport;
    livesync-a = config.system.build.appsLiveSyncExport;
    livesync-b = config.system.build.appsLiveSyncExport;
  };
  input = name: "/var/cache/restic-backups-${name}/apps-input";
in
{
  services.restic.backups = lib.mapAttrs (name: commands: {
    repositoryFile = "/run/backup-config/${name}-repository";
    passwordFile = "/run/backup-secrets/${name}-password";
    timerConfig = null;
    createWrapper = false;
    paths = [ (input name) ];
    backupPrepareCommand = ''
      #!${pkgs.runtimeShell}
      set -eu
      ${pkgs.coreutils}/bin/rm -rf -- ${lib.escapeShellArg (input name)}
      ${pkgs.coreutils}/bin/mkdir -m 700 -- ${lib.escapeShellArg (input name)}
      ${commands}/bin/prepare-reader --max-age 86400 ${lib.escapeShellArg (input name)}
    '';
    backupCleanupCommand = ''
      #!${pkgs.runtimeShell}
      set -eu
      ${pkgs.coreutils}/bin/rm -rf -- ${lib.escapeShellArg (input name)}
    '';
  }) jobs;

  systemd.services = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "restic-backups-${name}" {
      # Restic excludes its own cache from backups. Keep it beside the input.
      environment.RESTIC_CACHE_DIR = lib.mkForce "/var/cache/restic-backups-${name}/cache";
      serviceConfig = {
        TimeoutStartSec = "2h";
        TimeoutStopSec = "2min";
        KillMode = "control-group";
      };
    }
  ) jobs;
}
