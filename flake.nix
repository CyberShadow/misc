{
  description = "D programs repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        defaultNix = import ./default.nix {
          inherit pkgs;
          repo = ./.;
        };
      in
      {
        packages = defaultNix.programs // {
          default = pkgs.symlinkJoin {
            name = "misc";
            paths = builtins.attrValues defaultNix.programs;
          };
        };

        checks = defaultNix.tests;
      }
    ) // {
      overlays.default = final: prev: {
        dPrograms = self.packages.${prev.system};
      };
    };
}
