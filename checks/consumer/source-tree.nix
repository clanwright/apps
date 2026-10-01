{ ref }:
let
  header = source: {
    path = toString source.outPath;
    narHash = source.narHash or null;
    rev = source.rev or null;
    flake = source ? inputs;
    inputs = builtins.mapAttrs (_: input: toString input.outPath) (source.inputs or { });
  };
  node = source: {
    key = builtins.unsafeDiscardStringContext (builtins.toJSON (header source));
    inherit source;
  };
  project = source: {
    root = header source;
    sources = builtins.sort (a: b: builtins.toJSON a < builtins.toJSON b) (
      map (entry: builtins.fromJSON entry.key) (
        builtins.genericClosure {
          startSet = [ (node source) ];
          operator = entry: map node (builtins.attrValues (entry.source.inputs or { }));
        }
      )
    );
  };
  flake = builtins.getFlake ref;
in
{
  self = project flake;
  inputs = builtins.mapAttrs (_: project) flake.inputs;
}
