{
  description = "Clanwright application recipes for Obsidian LiveSync and Vaultwarden";

  inputs = {
    clan-core.url = "github:clan-lol/clan-core/c612dac4b2bfb5278b7c366f250044ddb5401bcb";
    network.url = "github:clanwright/network/bfba5e74c3ee09ab92534fc2e7fdf31dc4525bb2"; # v3.0.0
    primitives.url = "github:clanwright/primitives/9dd13dd84479914fe8465ff6f77d2bb1f8034e2e"; # v0.2.0
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
    in
    {
      clan.modules = {
        "@clanwright/apps-obsidian" = lib.modules.importApply ./clanServices/obsidian/default.nix {
          inherit lib;
          couchdbModule = primitives.nixosModules.couchdb;
        };
        "@clanwright/apps-vaultwarden" = lib.modules.importApply ./clanServices/vaultwarden/default.nix {
          inherit lib;
          postgresqlModule = primitives.nixosModules.postgresql;
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
    };
}
