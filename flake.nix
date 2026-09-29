{
  description = "Clanwright application recipes for Obsidian LiveSync and Vaultwarden";

  inputs = {
    clan-core.url = "github:clan-lol/clan-core/c612dac4b2bfb5278b7c366f250044ddb5401bcb";
    network.url = "github:clanwright/network/2981962f1f590fae66c05c50a3d793825281de9e"; # v4.0.0
    primitives.url = "github:clanwright/primitives/77e744cadad532e8458b19a8df71a97794434bf7"; # v0.2.1
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
      recoveryModule = {
        key = "${primitives.outPath}#nixosModules.recovery";
        imports = [ primitives.nixosModules.recovery ];
      };
    in
    {
      clan.modules = {
        "@clanwright/apps-obsidian" = lib.modules.importApply ./clanServices/obsidian/default.nix {
          inherit lib;
          couchdbModule = primitives.nixosModules.couchdb;
          inherit recoveryModule;
          recoveryToolsFor = system: primitives.lib.mkRecoveryTools { inherit system; };
          appsPkgsFor = system: import apps-nixpkgs { inherit system; };
        };
        "@clanwright/apps-vaultwarden" = lib.modules.importApply ./clanServices/vaultwarden/default.nix {
          inherit lib;
          postgresqlModule = primitives.nixosModules.postgresql;
          inherit recoveryModule;
          recoveryToolsFor = system: primitives.lib.mkRecoveryTools { inherit system; };
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
          apps-nixpkgs
          ;
      };
      checks.aarch64-linux.recovery-runtime = import ./checks/recovery-runtime.nix {
        inherit
          self
          clan-core
          primitives
          apps-nixpkgs
          ;
        system = "aarch64-linux";
      };
      checks.aarch64-linux.export-tools = import ./checks/export/check.nix {
        pkgs = import apps-nixpkgs { system = "aarch64-linux"; };
      };
      checks.aarch64-linux.export-runtime = import ./checks/export-runtime.nix {
        inherit
          self
          clan-core
          network
          apps-nixpkgs
          ;
        system = "aarch64-linux";
      };
      checks.aarch64-linux.validator-isolation = import ./checks/validate {
        pkgs = import apps-nixpkgs { system = "aarch64-linux"; };
      };
    };
}
