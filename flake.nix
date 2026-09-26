{
  description = "Clanwright application recipes for Obsidian LiveSync and Vaultwarden";

  inputs = {
    clan-core.url = "github:clan-lol/clan-core/3b5832a13fb0ad1e57c2dafd246ca8ab60ad1b20";
    network.url = "github:clanwright/network/v2.2.0";
    primitives.url = "github:clanwright/primitives/v0.1.0";
    apps-nixpkgs.url = "github:NixOS/nixpkgs/c27cdad491a991b11ed731760aa2ef8db0cb0410";
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
        "@clanwright/apps-livesync-couchdb" =
          lib.modules.importApply ./clanServices/livesync-couchdb/default.nix
            {
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
