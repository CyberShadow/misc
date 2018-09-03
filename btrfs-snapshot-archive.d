/// Copy snapshots from one volume to another.
/// Supports remote hosts for source or target (push or pull) using
/// ssh://user@host//path/to/btrfs/root URLs.
module btrfs_snapshot_archive;

import core.time;

import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.datetime.systime;
import std.exception;
import std.path;
import std.process;
import std.range;
import std.stdio : stderr, File;
import std.typecons;

import ae.sys.vfs;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta;
import ae.utils.time.parse;
import ae.utils.time.parsedur;

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
	Switch!("Be more verbose") verbose,
	Switch!("Delete redundant snapshots from the source afterwards") cleanUp,
	Switch!("Show transfer details by piping data through pv") pv,
	Switch!("Never copy snapshots whole (require a parent)") requireParent,
	Option!(string[], "Only copy snapshots matching this glob") mask = null,
	Option!(string[], "Do not copy snapshots matching this glob") notMask = null,
	Option!(string, "Only copy snapshots newer than this duration", "DUR") newerThan = null,
	Option!(string, "Leave a file in the source root dir for each successfully copied snapshot, based on the snapshot name and MARK", "MARK") successMark = null,
	Option!(string, "Name of file in subvolume root which indicates which subvolumes to skip", "MARK") noBackupFile = ".nobackup",
	Switch!("Only sync marks, don't copy new snapshots") markOnly = false,
)
{
	if (markOnly)
		enforce(successMark, "--mark-only only makes sense with --success-mark");

	import core.stdc.stdio : setvbuf, _IOLBF;
	setvbuf(stderr.getFP(), null, _IOLBF, 1024);

	string[][string] srcSubvolumes;
	HashSet!string[string] allSubvolumes;

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
		srcSubvolumes[name] ~= time;
		if (name !in allSubvolumes) allSubvolumes[name] = HashSet!string.init;
		allSubvolumes[name].add(time);
	}

	bool error;
	auto now = Clock.currTime;
	auto newerThanDur = newerThan ? newerThan.parseDuration : Duration.init;

	foreach (subvolume; srcSubvolumes.keys.sort)
	{
		auto srcSnapshots = srcSubvolumes[subvolume];
		srcSnapshots.sort();
		auto allSnapshots = allSubvolumes[subvolume].keys;
		allSnapshots.sort();

		stderr.writefln("> Subvolume %s", subvolume);

		// Remove live subvolume
		srcSnapshots = srcSnapshots.filter!(s => s.length > 0).array;

		while (srcSnapshots.length)
		{
			Tuple!(size_t, "distance", string, "snapshot") findParent(string snapshot)
			{
				auto snapshotIndex = allSnapshots.countUntil(snapshot);
				assert(snapshotIndex >= 0);
				foreach (distance, parentSnapshot; roundRobin(allSnapshots[snapshotIndex..$], allSnapshots[0..snapshotIndex].retro).enumerate)
				{
					if (!parentSnapshot.length)
						continue;
					auto parentSubvolume = subvolume ~ "-" ~ parentSnapshot;
					//debug stderr.writefln(">>> Checking for parent: %s", dstParentPath);
					if (parentSubvolume in srcDir && (parentSubvolume ~ ".partial") !in srcDir &&
						parentSubvolume in dstDir && (parentSubvolume ~ ".partial") !in dstDir)
						return typeof(return)(distance, parentSnapshot);
				}
				return typeof(return)(size_t.max - 1, string.init);
			}

			// Find the snapshot closest to an existing one.
			auto snapshotIndex = {
				string bestSnapshot;
				size_t bestDistance = size_t.max;
				foreach (snapshotIndex, snapshot; srcSnapshots)
				{
					auto parent = findParent(snapshot);
					if (bestDistance > parent.distance)
					{
						bestDistance = parent.distance;
						bestSnapshot = snapshot;
					}
				}
				assert(bestSnapshot);
				return srcSnapshots.countUntil(bestSnapshot);
			}();
			assert(snapshotIndex >= 0);
			auto snapshot = srcSnapshots[snapshotIndex];
			srcSnapshots = srcSnapshots.remove(snapshotIndex);

			bool snapshotHeaderLogged = false;
			void needSnapshotHeader() { if (prog1(!snapshotHeaderLogged, snapshotHeaderLogged = true)) stderr.writefln(">> Snapshot %s", snapshot); }
			if (verbose) needSnapshotHeader();

			try
			{
				auto snapshotSubvolume = subvolume ~ "-" ~ snapshot;
				auto srcPath = buildPath(srcRoot, snapshotSubvolume);
				assert(snapshotSubvolume in srcDir); //assert(srcPath.exists);
				auto dstPath = buildPath(dstRoot, snapshotSubvolume);
				auto flagPath = dstPath ~ ".partial";

				if (snapshotSubvolume ~ ".partial" in srcDir)
				{
					if (verbose) stderr.writefln(">>> Source has .partial flag, skipping");
					continue;
				}

				if (mask.length && !mask.any!(m => globMatch(snapshotSubvolume, m)))
				{
					if (verbose) stderr.writefln(">>> Mask mismatch, skipping");
					continue;
				}

				if (notMask.any!(m => globMatch(snapshotSubvolume, m)))
				{
					if (verbose) stderr.writefln(">>> Not-mask match, skipping");
					continue;
				}

				void createMark()
				{
					if (successMark)
					{
						auto markPath = srcPath ~ ".success-" ~ successMark;
						if (markPath.baseName !in srcDir)
						{
							needSnapshotHeader(); stderr.writefln(">>> Creating mark: %s", markPath);
							if (!dryRun)
								write(markPath, "");
						}
					}
				}

				if (snapshotSubvolume in dstDir) // dstPath.exists
				{
					if (snapshotSubvolume ~ ".partial" in dstDir) // flagPath.exists
					{
						if (verbose) stderr.writeln(">>> Acquiring lock...");
						auto flag = Lock(flagPath);

						needSnapshotHeader(); stderr.writeln(">>> Cleaning up partially-received snapshot");
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
						if (verbose) stderr.writeln(">>> Already in destination, skipping");
						createMark();
						continue;
					}
				}
				else
				{
					if (snapshotSubvolume ~ ".partial" in dstDir) // flagPath.exists
					{
						needSnapshotHeader(); stderr.writeln(">>> Deleting orphan flag file: ", flagPath);
						if (!dryRun)
							flagPath.remove();
					}
				}
				if (markOnly)
				{
					if (verbose) stderr.writeln(">>> --mark-only specified, skipping");
					continue;
				}

				assert(!flagPath.exists || dryRun);
				assert(!dstPath.exists || dryRun);

				if (srcPath.buildPath(noBackupFile).exists)
				{
					if (verbose) stderr.writefln(">>> Has no-backup file (%s), skipping", srcPath.buildPath(noBackupFile));
					continue;
				}

				if (!srcPath.exists)
				{
					if (verbose) stderr.writefln(">>> Gone, skipping");
					continue;
				}

				auto info = btrfs_subvolume_show(srcPath);
				if (!info["Flags"].split(" ").canFind("readonly"))
				{
					if (verbose) stderr.writeln(">>> Not readonly, skipping");
					continue;
				}

				auto creationTime = info["Creation time"].parseTime!`Y-m-d H:i:s O`;
				if (newerThan && now - creationTime < newerThanDur)
				{
					if (verbose) stderr.writefln(">>> Too old (created %s ago), skipping", now - creationTime);
					continue;
				}

				string parentSubvolume;
				{
					auto parent = findParent(snapshot);
					if (parent.snapshot)
					{
						if (verbose) stderr.writefln(">>> Found parent: %s", parent.snapshot);
						parentSubvolume = parent.snapshot ? subvolume ~ "-" ~ parent.snapshot : null;
					}
				}
				if (!parentSubvolume)
				{
					enforce(!requireParent, "No parent found, skipping");
					needSnapshotHeader(); stderr.writefln(">>> No parent found, sending whole.");
				}

				auto sendArgs = ["btrfs", "send"];
				if (parentSubvolume)
				{
					auto srcParentPath = buildPath(srcRoot, parentSubvolume);
					assert(srcParentPath.exists);
					sendArgs ~= ["-p", srcParentPath];
				}

				sendArgs ~= srcPath;
				auto recvArgs = ["btrfs", "receive", dstRoot];

				sendArgs = remotify(sendArgs);
				recvArgs = remotify(recvArgs);

				needSnapshotHeader();
				if (verbose) stderr.writefln(">>> %s | %s", sendArgs.escapeShellCommand, recvArgs.escapeShellCommand);
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
							if (verbose) stderr.writefln(">>>> Done.");
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
					if (verbose) stderr.writeln(">>>> OK");
				}

				if (parentSubvolume && cleanUp)
				{
					stderr.writefln(">>> Clean-up: parent %s", parentSubvolume);
					if (!dryRun)
					{
						assert(dstPath.exists);
						auto srcParentPath = buildPath(srcRoot, parentSubvolume);
						btrfs_subvolume_delete(srcParentPath);
						if (verbose) stderr.writeln(">>>> OK");
					}
				}

				createMark();
				dstDir.add(snapshotSubvolume);
			}
			catch (Exception e)
			{
				needSnapshotHeader(); stderr.writefln(">>> Error! %s", e.msg);
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
