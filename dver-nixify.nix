{ pkgs2024 ?
  import (fetchTarball {
    # A known-working version, nixpkgs as of 2024-01-01.
    url = "https://github.com/NixOS/nixpkgs/archive/0ef56bec7281e2372338f2dfe7c13327ce96f6bb.tar.gz";
    sha256 = "sha256:0yzj46sd0q1zbz1xxzvf0dldm3g67nad8m0h1ks89d81vc3nr653";
  }) {}
, pkgs ? pkgs2024
, dir
}:
let
  patch = source: libPkgs:
    pkgs.stdenvNoCC.mkDerivation {
      name = "dver-nixified";
      dontUnpack = true;
      src = source;
      buildInputs = [
        libPkgs.libgcc
        libPkgs.libgcc.lib
        libPkgs.libstdcxx5
      ];
      nativeBuildInputs = [
        libPkgs.autoPatchelfHook
      ];
      buildPhase = ''
        cp -a $src $out
      '';
    };
in
pkgs.lib.lists.foldl patch dir [
  pkgs
  pkgs.pkgsi686Linux
]
