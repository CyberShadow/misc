{ pkgs ? import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/c00f20377be57a37df5cf7986198aab6051c0057.tar.gz";
    sha256 = "sha256:0y5lxq838rzia2aqf8kh2jdv8hzgi7a6hlswsklzkss27337hrcn";
}) {}
, repo ? builtins.fetchGit ./.
}:

let
  lib = pkgs.lib;

  # Helper function to read file contents
  readFile = file: builtins.readFile (toString ./${file});

  query = command:
    builtins.readFile (pkgs.runCommand "query" {} ''
      ${command} > $out
    '');

  splitLines = str:
    let
      split = builtins.split "\n" str;
      convert = input: output:
        if builtins.length input <= 1 then
          output
        else
          convert
            (builtins.tail (builtins.tail input))
            ([(builtins.head input)] ++ output);
    in
      convert split [];

  # Get all versioned files
  versionedFiles = map
    (f: f.name)
    (builtins.filter
      (f: f.value == "regular")
      (lib.attrsToList (builtins.readDir repo))
    );

  # Get all .d files
  dFiles = builtins.filter (f: lib.hasSuffix ".d" f) versionedFiles;

  # Get .d files with main function
  dFilesWithMain = builtins.filter (f: builtins.match ".*[^a-z]main[^a-z].*" (readFile f) != null) dFiles;

  # Get buildable .d files
  buildableDFiles = builtins.filter (f: !(builtins.match ".*import mylib\..*" (readFile f) != null)) dFilesWithMain;

  # Get files with shebang
  filesWithShebang = builtins.filter (f: builtins.match "#!.*" (readFile f) != null) versionedFiles;

  # Get files with D shebang
  filesWithDShebang = builtins.filter (f:
    builtins.match "#!/usr/bin/env dub.*" (readFile f) != null ||
    builtins.match ".*\n#! nix-shell -i.*dub.*" (readFile f) != null
  ) versionedFiles;

  # Get executable files
  # executableFiles = builtins.filter (f: (builtins.readDir ./.).${f}.type == "executable") versionedFiles;
  executableFiles = splitLines
    (query "env -C ${repo} find ${lib.escapeShellArgs versionedFiles} -maxdepth 0 -executable");

  # Test 1: A file has a shebang iff it is executable
  test-shebang-executable = pkgs.runCommand "test-shebang-executable" {} ''
    diff \
      <(printf '%s\n' ${lib.escapeShellArgs filesWithShebang} | sort) \
      <(printf '%s\n' ${lib.escapeShellArgs executableFiles} | sort)
    touch $out
  '';

  # Test 2: A file has a D shebang iff it is a buildable D program
  test-shebang-buildable = pkgs.runCommand "test-shebang-buildable" {} ''
    diff \
      <(printf '%s\n' ${lib.escapeShellArgs filesWithDShebang} | sort) \
      <(printf '%s\n' ${lib.escapeShellArgs buildableDFiles} | sort)
    touch $out
  '';

  # Test 3: Buildable D programs pass unittests
  testableDFiles = builtins.filter (f:
		# Has "rt_cmdline_enabled = false", can't use --DRT-testmode=test-only
    !(builtins.match ".*import drunner;.*" (readFile f) != null)
  ) buildableDFiles;

  dLibs = pkgs.symlinkJoin {
    name = "my-libs";
    paths = [
      pkgs.zlib
      (pkgs.lib.getLib pkgs.openssl)
      pkgs.xorg.libX11
      (pkgs.lib.getLib pkgs.ncurses)
    ];
  };

  dDeps = [
    # {
    #   pname = "ae";
    #   version = "0.0.3236";
    #   sha256 = "sha256:0by9yclvk795nw7ilwhv7wh17j2dd7xk54phs8s5jxrwpqx10x52";
    # }
    {
      pname = "ae";
      version = "0.0.3569";
      sha256 = "sha256:0hnygwlqmcj63yi65jfsqz89vvazrgv1di4p9hvjp4h9rs72zrpd";
    }
    {
      pname = "ae";
      version = "0.0.3573";
      sha256 = "sha256:1pvfjam5dgzffwh5w6i37wzpf1x5aij58hgs07bb00qyrz21pyqb";
    }
    {
      pname = "chunker";
      version = "0.0.1";
      sha256 = "sha256:04bps3hbm8zkb64553hbpcyan203xkdl63yqmsx72wymwnavjij6";
    }
    {
      pname = "ncurses";
      version = "1.0.0";
      sha256 = "sha256:0ivl88vp2dy9rpv6x3f9jlyqa7aps2x1kkyx80w2d4vcs31pzmb2";
    }
    {
      pname = "libx11";
      version = "0.0.1";
      sha256 = "sha256:0p9gk9q98hkfn3i02lzvnvr0crjdvcr9l4pawlzxjbs3rr8lmsiw";
    }
  ];

  fetchDDep = dep:
    let
      zip = builtins.fetchurl {
        url = "https://code.dlang.org/packages/${dep.pname}/${dep.version}.zip";
        sha256 = dep.sha256;
      };
    in
      pkgs.linkFarm "dub-${dep.pname}-${dep.version}-zip" {
        "${dep.pname}-${dep.version}.zip" = zip;
      };

  dProgram = f:
    let
      name = lib.removeSuffix ".d" f;
      buildCommon = ''
        export HOME=/build
        ${lib.concatMapStringsSep "\n" (dep: ''
          dub fetch ${dep.pname}@${dep.version} --cache=user --skip-registry=standard --registry=file://${fetchDDep dep}
        '') dDeps}
        ln -vs ${./${f}} ./${f}
        ${lib.optionalString (builtins.match ".*import btrfs_common;.*" (readFile f) != null) ''
          ln -vs ${./btrfs_common.d} ./btrfs_common.d
          ln -vs ${./btrfs_ssh_lock.pl} ./btrfs_ssh_lock.pl
        ''}${lib.optionalString (builtins.match ".*import drunner;.*" (readFile f) != null) ''
          ln -vs ${./drunner.d} ./drunner.d
        ''}${lib.optionalString (builtins.match ".*import linux_config_common;.*" (readFile f) != null) ''
          ln -vs ${./linux_config_common.d} ./linux_config_common.d
        ''}${lib.optionalString (builtins.match ".*path-treemap-viewer.html.*" (readFile f) != null) ''
          ln -vs ${./path-treemap-viewer.html} ./path-treemap-viewer.html
        ''}${lib.optionalString (builtins.match ".*dver-nixify.nix.*" (readFile f) != null) ''
          ln -vs ${./dver-nixify.nix} ./dver-nixify.nix
        ''}
      '';
    in
      pkgs.stdenv.mkDerivation (finalAttrs: {
        inherit name;
        src = f;
        dontUnpack = true;
        buildInputs = [
          pkgs.dmd
          pkgs.dub
        ];
        buildPhase = ''
          ${buildCommon}
          DFLAGS="-L-L${dLibs}/lib" dub build --single ${name}.d --skip-registry=standard
        '';
        installPhase = ''
          mkdir -p $out/bin
          cp ${name} $out/bin
        '';
        passthru.tests.unittest = pkgs.runCommand "test-d-unittest-${f}" {
          inherit (finalAttrs) src buildInputs;
        } ''
          ${buildCommon}
          DFLAGS="-unittest -L-L${dLibs}/lib" dub --single ${name}.d --skip-registry=standard -- --DRT-testmode=test-only
          touch $out
        '';
      });

  programs = builtins.listToAttrs
    (map (f: {
      inherit (dProgram f) name;
      value = dProgram f;
    })
      buildableDFiles);

  test-all-d-unittests = builtins.listToAttrs
    (map (f: {
      name = "unittest-${(dProgram f).name}";
      value = (dProgram f).passthru.tests.unittest;
    })
      testableDFiles);

in {
  inherit programs;
  tests = {
    inherit test-shebang-executable;
    inherit test-shebang-buildable;
  } // test-all-d-unittests;
}
