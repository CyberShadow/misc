# End-to-end test of btrfs-snapshot-archive and btrfs-snapshot-cleanup,
# with local, pushed (ssh destination) and pulled (ssh source) transfers.
{ pkgs, programs }:

let
  sshKeys = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;

  node = { ... }: {
    virtualisation.emptyDiskImages = [ 1024 ];
    services.openssh.enable = true;
    users.users.root.openssh.authorizedKeys.keys = [ sshKeys.snakeOilPublicKey ];
    programs.ssh.extraConfig = ''
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    '';
    environment.systemPackages = [
      pkgs.btrfs-progs
      pkgs.jq
      pkgs.ncdu
      pkgs.perl # for btrfs_ssh_lock.pl
      programs.btrfs-snapshot-archive
      programs.btrfs-snapshot-cleanup
      programs.btrfs-send-treemap
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "btrfs-snapshots";

  nodes.source = node;
  nodes.dest = node;

  testScript = ''
    import json

    start_all()
    for machine in [source, dest]:
        machine.wait_for_unit("sshd.service")
        machine.succeed(
            "mkfs.btrfs /dev/vdb",
            "mkdir -p /mnt/btrfs",
            "mount /dev/vdb /mnt/btrfs",
            "install -D -m 600 ${sshKeys.snakeOilPrivateKey} /root/.ssh/id_ecdsa",
        )

    def lines(output):
        return output.splitlines()

    def metadata(machine, path):
        return json.loads(machine.succeed(f"cat {path}"))

    # Create two snapshots. The second one creates a directory, which
    # btrfs send creates under a temporary name and renames later.
    source.succeed(
        "mkdir /mnt/btrfs/src",
        "btrfs subvolume create /mnt/btrfs/src/@data",
        "head -c 1048576 /dev/urandom > /mnt/btrfs/src/@data/old",
        "btrfs subvolume snapshot -r /mnt/btrfs/src/@data /mnt/btrfs/src/@data-20260101000000",
        "mkdir -p /mnt/btrfs/src/@data/new/subdir",
        "head -c 2097152 /dev/urandom > /mnt/btrfs/src/@data/new/subdir/file",
        "rm /mnt/btrfs/src/@data/old",
        "btrfs subvolume snapshot -r /mnt/btrfs/src/@data /mnt/btrfs/src/@data-20260102000000",
    )

    with subtest("push to an ssh destination"):
        dest.succeed("mkdir /mnt/btrfs/pushed")
        out = source.succeed(
            "btrfs-snapshot-archive --success-mark push /mnt/btrfs/src ssh://root@dest//mnt/btrfs/pushed"
        )
        assert lines(out) == [
            "ssh://root@dest//mnt/btrfs/pushed/@data-20260101000000.json",
            "ssh://root@dest//mnt/btrfs/pushed/@data-20260102000000.json",
        ], out

        m = metadata(dest, "/mnt/btrfs/pushed/@data-20260101000000.json")
        assert m["version"] == 1, m
        assert m["delta"]["streamVersion"] == 2, m
        assert m["delta"]["parent"] is None, m
        assert m["delta"]["tree"]["children"]["old"]["size"] == 1048576, m

        m = metadata(dest, "/mnt/btrfs/pushed/@data-20260102000000.json")
        assert m["delta"]["parent"] == "@data-20260101000000", m
        tree = m["delta"]["tree"]
        assert set(tree["children"]) == {"new"}, tree  # "old" was deleted
        assert tree["children"]["new"]["size"] == 2097152, tree
        assert tree["children"]["new"]["children"]["subdir"]["children"]["file"]["size"] == 2097152, tree
        assert tree["size"] == 2097152, tree

        mark = source.succeed("cat /mnt/btrfs/src/@data-20260102000000.success-push")
        assert mark == "ssh://root@dest//mnt/btrfs/pushed/@data-20260102000000", mark

        dest.succeed("btrfs-send-treemap /mnt/btrfs/pushed/@data-20260102000000.json --out-file-name /tmp/treemap.html")
        dest.succeed("grep -F subdir /tmp/treemap.html")
        out = dest.succeed(
            "btrfs-send-treemap --ncdu /mnt/btrfs/pushed/@data-*.json | ncdu -f- -o-"
        )
        assert "subdir" in out and "old" in out, out

    with subtest("pull from an ssh source"):
        dest.succeed("mkdir /mnt/btrfs/pulled")
        out = dest.succeed(
            "btrfs-snapshot-archive --success-mark pull ssh://root@source//mnt/btrfs/src /mnt/btrfs/pulled"
        )
        assert lines(out) == [
            "/mnt/btrfs/pulled/@data-20260101000000.json",
            "/mnt/btrfs/pulled/@data-20260102000000.json",
        ], out
        mark = source.succeed("cat /mnt/btrfs/src/@data-20260102000000.success-pull")
        assert mark == "ssh://dest//mnt/btrfs/pulled/@data-20260102000000", mark

    with subtest("archive locally"):
        dest.succeed("mkdir /mnt/btrfs/local")
        dest.succeed("btrfs-snapshot-archive --success-mark local /mnt/btrfs/pulled /mnt/btrfs/local")
        mark = dest.succeed("cat /mnt/btrfs/pulled/@data-20260101000000.success-local")
        assert mark == "ssh://dest//mnt/btrfs/local/@data-20260101000000", mark

    with subtest("cleanup deletes sidecars and shows local copies"):
        out = dest.succeed("btrfs-snapshot-cleanup --keep 0 --show-copies /mnt/btrfs/pulled")
        assert lines(out) == [
            "# To also delete copies of the deleted snapshots, run:",
            "sudo btrfs subvolume delete -c /mnt/btrfs/local/@data-20260101000000 /mnt/btrfs/local/@data-20260102000000",
            "sudo rm -f /mnt/btrfs/local/@data-20260101000000.json /mnt/btrfs/local/@data-20260102000000.json",
        ], out
        dest.succeed("test -z \"$(ls /mnt/btrfs/pulled)\"")

    with subtest("purge shows remote copies"):
        # A snapshot marked before marks recorded the destination.
        source.succeed(
            "btrfs subvolume snapshot -r /mnt/btrfs/src/@data /mnt/btrfs/src/@data-20260103000000",
            "touch /mnt/btrfs/src/@data-20260103000000.success-push",
        )
        out = source.succeed("btrfs-snapshot-cleanup --mark push --keep 0 --show-copies /mnt/btrfs/src")
        assert lines(out) == [
            "# To also delete copies of the deleted snapshots, run:",
            "ssh dest sudo btrfs subvolume delete -c /mnt/btrfs/pulled/@data-20260101000000 /mnt/btrfs/pulled/@data-20260102000000",
            "ssh dest sudo rm -f /mnt/btrfs/pulled/@data-20260101000000.json /mnt/btrfs/pulled/@data-20260102000000.json",
            "ssh root@dest btrfs subvolume delete -c /mnt/btrfs/pushed/@data-20260101000000 /mnt/btrfs/pushed/@data-20260102000000",
            "ssh root@dest rm -f /mnt/btrfs/pushed/@data-20260101000000.json /mnt/btrfs/pushed/@data-20260102000000.json",
            "# @data-20260103000000.success-push: unknown destination",
        ], out
        source.succeed("test \"$(ls /mnt/btrfs/src)\" = @data")

        # The pulled copies were already deleted above; run the rest.
        source.succeed(out.splitlines()[3], out.splitlines()[4])
        dest.succeed("test -z \"$(ls /mnt/btrfs/pushed)\"")

    with subtest("orphan sidecars are cleaned up"):
        dest.succeed("touch /mnt/btrfs/local/@data-20250101000000.json /mnt/btrfs/local/@data-20250101000000.success-x")
        dest.succeed("btrfs-snapshot-cleanup --keep 100 --clean-marks /mnt/btrfs/local")
        dest.succeed("test \"$(ls /mnt/btrfs/local | sort)\" = \"$(printf '%s\\n' @data-20260101000000 @data-20260101000000.json @data-20260102000000 @data-20260102000000.json)\"")
  '';
}
