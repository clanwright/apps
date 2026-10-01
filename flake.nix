{
  description = "Clanwright application recipes for Obsidian LiveSync and Vaultwarden";

  inputs = {
    clan-core.url = "github:clan-lol/clan-core/c612dac4b2bfb5278b7c366f250044ddb5401bcb";
    network.url = "github:clanwright/network/9421c102c9536a4345446a74aaaeb603cb6a23e3"; # v1.0.0
    primitives.url = "github:clanwright/primitives/8e64d6c436af087684acaed0cc3190a3062c2233"; # v1.0.0
    apps-nixpkgs.url = "github:NixOS/nixpkgs/8d5d270900d3fc75655ea2d9d248b234f6631439";
  };

  outputs =
    {
      self,
      clan-core,
      network,
      primitives,
      apps-nixpkgs,
      ...
    }:
    let
      lib = clan-core.inputs.nixpkgs.lib;
      # Supported component cohort of this same Primitives artifact's module.
      couchdbErlangFor =
        system: primitives.inputs.nixpkgs.legacyPackages.${system}.beamMinimalPackages.erlang;
    in
    {
      clan.modules = {
        "@clanwright/apps-obsidian" = lib.modules.importApply ./clanServices/obsidian/default.nix {
          inherit lib couchdbErlangFor;
          couchdbModule = primitives.nixosModules.couchdb;
          recoveryToolsFor = pkgs: primitives.lib.mkRecoveryTools { inherit pkgs; };
        };
        "@clanwright/apps-vaultwarden" = lib.modules.importApply ./clanServices/vaultwarden/default.nix {
          inherit lib;
          postgresqlModule = primitives.nixosModules.postgresql;
          recoveryToolsFor = pkgs: primitives.lib.mkRecoveryTools { inherit pkgs; };
          appsPkgsFor = system: import apps-nixpkgs { inherit system; };
        };
      };
      clanModules.default = ./modules/configuration.nix;
      packages.x86_64-linux.vaultwarden = (import apps-nixpkgs { system = "x86_64-linux"; }).vaultwarden;
      checks.x86_64-linux.contract = import ./checks/contract.nix {
        inherit
          self
          clan-core
          network
          primitives
          apps-nixpkgs
          ;
      };
      checks.x86_64-linux.http-runtime = import ./checks/http-runtime.nix {
        inherit self clan-core network;
      };
      checks.x86_64-linux.recovery-runtime = import ./checks/recovery-runtime.nix {
        inherit
          self
          clan-core
          primitives
          couchdbErlangFor
          ;
      };
      checks.aarch64-linux.recovery-runtime = import ./checks/recovery-runtime.nix {
        inherit
          self
          clan-core
          primitives
          couchdbErlangFor
          ;
        system = "aarch64-linux";
      };
      checks.aarch64-linux.export-tools = import ./checks/export/check.nix {
        pkgs = import apps-nixpkgs { system = "aarch64-linux"; };
      };
    };
}
