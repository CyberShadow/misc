/// Copy snapshots from one volume to another.
/// Supports remote hosts for source or target (push or pull) using
/// ssh://user@host//path/to/btrfs/root URLs.
module btrfs_snapshot_archive;

import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.exception;
import std.path;
import std.process;
import std.range;
import std.stdio : stderr, File;

import ae.sys.vfs;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;

import btrfs_common;

/*
  - For each subvolume:
    - Find common parent
      - If no common parent, send whole
    - Send (minding parent) + receive (minding parent, to temporary subvolume name)
    - If successful, move temporary subvolume
    - Delete the PARENT subvolume from source

  - TODO:
    - don't use -p, use -c,
 */

int btrfs_snapshot_archive(
	Parameter!(string, "Path to source btrfs root directory") srcRoot,
	Parameter!(string, "Path to target btrfs root directory") dstRoot,
	Switch!("Dry run (only pretend to do anything)") dryRun,
	Switch!("Delete redundant snapshots from the source afterwards") cleanUp,
	Switch!("Show transfer details by piping data through pv") pv,
	Switch!("Never copy snapshots whole (require a parent)") requireParent,
	Option!(string, "Only copy snapshots matching this glob") mask = null,
	Option!(string, "Do not copy snapshots matching this glob") notMask = null,
	Option!(string, "Leave a file in the source root dir for each successfully copied snapshot, based on the snapshot name and MARK", "MARK") successMark = null,
	Option!(string, "Name of file in subvolume root which indicates which subvolumes to skip", "MARK") noBackupFile = ".nobackup",
	Switch!("Only sync marks, don't copy new snapshots") markOnly = false,
)
{
	if (markOnly)
		enforce(successMark, "--mark-only only makes sense with --success-mark");

	import core.stdc.stdio : setvbuf, _IOLBF;
	setvbuf(stderr.getFP(), null, _IOLBF, 1024);

	string[][string] allSnapshots;

	stderr.writefln("> Enumerating %s", srcRoot);
	auto srcDir = srcRoot.listDir.toSet;
	stderr.writefln("> Enumerating %s", dstRoot);
	auto dstDir = dstRoot.listDir.toSet;

	foreach (name; srcDir.byKey)
	{
		if (!name.startsWith("@"))
		{
			stderr.writeln("Invalid name, skipping: " ~ name);
			continue;
		}
		auto parts = name.findSplit("-");
		string time = null;
		if (parts[1].length)
		{
			time = parts[2];
			name = parts[0];
		}
		if (time.canFind("."))
		{
			//stderr.writeln("Flag file, skipping: " ~ name);
			continue;
		}
		allSnapshots[name] ~= time;
	}

	bool error;

	foreach (subvolume, snapshots; allSnapshots)
	{
		snapshots.sort();
		stderr.writefln("> Subvolume %s", subvolume);

		foreach (snapshotIndex, snapshot; snapshots)
		{
			if (!snapshot.length)
				continue; // live subvolume
			stderr.writefln(">> Snapshot %s", snapshot);

			try
			{
				auto snapshotSubvolume = subvolume ~ "-" ~ snapshot;
				auto srcPath = buildPath(srcRoot, snapshotSubvolume);
				assert(snapshotSubvolume in srcDir); //assert(srcPath.exists);
				auto dstPath = buildPath(dstRoot, snapshotSubvolume);
				auto flagPath = dstPath ~ ".partial";

				if (mask && !globMatch(snapshotSubvolume, mask))
				{
					stderr.writefln(">>> Mask mismatch, skipping");
					continue;
				}

				if (notMask && globMatch(snapshotSubvolume, notMask))
				{
					stderr.writefln(">>> Not-mask match, skipping");
					continue;
				}

				void createMark()
				{
					if (successMark)
					{
						auto markPath = srcPath ~ ".success-" ~ successMark;
						if (markPath.baseName !in srcDir)
						{
							stderr.writefln(">>> Creating mark: %s", markPath);
							if (!dryRun)
								write(markPath, "");
						}
					}
				}

				if (snapshotSubvolume in dstDir) // dstPath.exists
				{
					if (snapshotSubvolume ~ ".partial" in dstDir) // flagPath.exists
					{
						stderr.writeln(">>> Acquiring lock...");
						auto flag = Lock(flagPath);

						stderr.writeln(">>> Cleaning up partially-received snapshot");
						if (!dryRun)
						{
							btrfs_subvolume_delete(dstPath);
							// sync();
							flagPath.remove();
							stderr.writeln(">>>> OK");
						}
					}
					else
					{
						stderr.writeln(">>> Already in destination, skipping");
						createMark();
						continue;
					}
				}
				else
				{
					if (snapshotSubvolume ~ ".partial" in dstDir) // flagPath.exists
					{
						stderr.writeln(">>> Deleting orphan flag file: ", flagPath);
						if (!dryRun)
							flagPath.remove();
					}
				}
				if (markOnly)
				{
					stderr.writeln(">>> --mark-only specified, skipping");
					continue;
				}

				assert(!flagPath.exists || dryRun);
				assert(!dstPath.exists || dryRun);

				if (srcPath.buildPath(noBackupFile).exists)
				{
					stderr.writefln(">>> Has no-backup file (%s), skipping", srcPath.buildPath(noBackupFile));
					continue;
				}

				if (!srcPath.exists)
				{
					stderr.writefln(">>> Gone, skipping");
					continue;
				}

				auto info = btrfs_subvolume_show(srcPath);
				if (!info["Flags"].split(" ").canFind("readonly"))
				{
					stderr.writeln(">>> Not readonly, skipping");
					continue;
				}

				string parent;
				foreach (parentSnapshot; chain(snapshots[0..snapshotIndex].retro, snapshots[snapshotIndex..$]))
				{
					auto parentSubvolume = subvolume ~ "-" ~ parentSnapshot;
					auto dstParentPath = buildPath(dstRoot, parentSubvolume);
					//debug stderr.writefln(">>> Checking for parent: %s", dstParentPath);
					if (dstParentPath.exists && !(dstParentPath ~ ".partial").exists)
					{
						stderr.writefln(">>> Found parent: %s", parentSnapshot);
						parent = parentSubvolume;
						break;
					}
				}
				if (!parent)
				{
					enforce(!requireParent, "No parent found, skipping");
					stderr.writefln(">>> No parent found, sending whole.");
				}

				auto sendArgs = ["btrfs", "send"];
				if (parent)
				{
					auto srcParentPath = buildPath(srcRoot, parent);
					assert(srcParentPath.exists);
					sendArgs ~= ["-p", srcParentPath];
				}

				sendArgs ~= srcPath;
				auto recvArgs = ["btrfs", "receive", dstRoot];

				sendArgs = remotify(sendArgs);
				recvArgs = remotify(recvArgs);

				stderr.writefln(">>> %s | %s", sendArgs.escapeShellCommand, recvArgs.escapeShellCommand);
				if (!dryRun)
				{
					auto flag = Lock(flagPath);
					// sync();
					scope(exit) flagPath.remove();

					scope(failure)
					{
						if (dstPath.exists)
						{
							stderr.writefln(">>> Error, deleting partially-sent subvolume...");
							btrfs_subvolume_delete(dstPath);
							// sync();
							stderr.writefln(">>>> Done.");
						}
					}

					auto btrfsPipe = pipe();
					File readEnd, writeEnd;
					Pid pvPid;

					if (pv)
					{
						auto pvPipe = pipe();
						pvPid = spawnProcess(["pv"], btrfsPipe.readEnd, pvPipe.writeEnd);
						writeEnd = btrfsPipe.writeEnd;
						readEnd = pvPipe.readEnd;
					}
					else
					{
						readEnd = btrfsPipe.readEnd;
						writeEnd = btrfsPipe.writeEnd;
					}

					auto sendPid = spawnProcess(sendArgs, File("/dev/null"), writeEnd);
					auto recvPid = spawnProcess(recvArgs, readEnd, stderr);
					enforce(recvPid.wait() == 0, "btrfs-receive failed");
					enforce(sendPid.wait() == 0, "btrfs-send failed");
					if (pv)
						enforce(pvPid.wait() == 0, "pv failed");
					enforce(dstPath.exists, "Sent subvolume does not exist: " ~ dstPath);
					stderr.writeln(">>>> OK");
				}

				if (parent && cleanUp)
				{
					stderr.writefln(">>> Clean-up: parent %s", parent);
					if (!dryRun)
					{
						assert(dstPath.exists);
						auto srcParentPath = buildPath(srcRoot, parent);
						btrfs_subvolume_delete(srcParentPath);
						stderr.writeln(">>>> OK");
					}
				}

				createMark();
			}
			catch (Exception e)
			{
				stderr.writefln(">>> Error! %s", e.msg);
				error = true;
			}
		}
	}
	if (error)
		stderr.writeln("> Done with some errors.");
	else
		stderr.writeln("> Done with no errors.");
	return error ? 2 : 0;
}

mixin main!(funopt!btrfs_snapshot_archive);
