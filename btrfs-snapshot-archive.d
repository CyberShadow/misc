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
import std.format;
import std.path;
import std.process;
import std.range;
import std.stdio : stderr, File;
import std.string : indexOf;
import std.typecons;

import ae.sys.vfs;
import ae.utils.aa;
import ae.utils.array;
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

enum RsyncCondition
{
	never,
	error,
	always,
}

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
	Option!(string, "Only copy snapshots older than this duration", "DUR") olderThan = null,
	Option!(string, "Only copy snapshots newer than this duration", "DUR") newerThan = null,
	Switch!("When copying a new subvolume and snapshot set, start with the newest snapshot") newerFirst = false,
	Option!(string, "Leave a file in the source root dir for each successfully copied snapshot, based on the snapshot name and MARK", "MARK") successMark = null,
	Option!(string, "Name of file in subvolume root which indicates which subvolumes to skip", "MARK") noBackupFile = ".nobackup",
	Switch!("Only sync marks, don't copy new snapshots") markOnly = false,
	Switch!("Create a \"latest\" symbolic link, pointing at the lexicographically highest snapshot") createLatestSymlink = false,
	Option!(RsyncCondition, "When to use rsync instead of btrfs-send/receive (never/error/always). 'error' tries btrfs-send/receive first, and falls back to rsync on error.", "WHEN") rsync = RsyncCondition.never,
)
{
	if (markOnly)
		enforce(successMark, "--mark-only only makes sense with --success-mark");

	import core.stdc.stdio : setvbuf, _IOLBF;
	setvbuf(stderr.getFP(), null, _IOLBF, 1024);

	HashSet!string[string] srcSubvolumes, allSubvolumes;

	stderr.writefln("> Enumerating %s", srcRoot);
	auto srcDir = srcRoot.listDir.toSet;
	stderr.writefln("> Enumerating %s", dstRoot);
	auto dstDir = dstRoot.listDir.toSet;

	foreach (fileName; chain(srcDir.byKey, dstDir.byKey))
	{
		if (!fileName.startsWith("@"))
		{
			stderr.writeln("Invalid name, skipping: " ~ fileName);
			continue;
		}
		auto parts = fileName.findSplit("-");
		string name, time;
		if (parts[1].length)
		{
			time = parts[2];
			name = parts[0];
		}
		else
			name = fileName;
		if (time.canFind("."))
		{
			//stderr.writeln("Flag file, skipping: " ~ name);
			continue;
		}
		if (fileName in srcDir) srcSubvolumes.getOrAdd(name).add(time);
		if (true              ) allSubvolumes.getOrAdd(name).add(time);
	}

	bool error, warning;
	auto now = Clock.currTime;
	auto newerThanDur = newerThan ? newerThan.parseDuration : Duration.init;
	auto olderThanDur = olderThan ? olderThan.parseDuration : Duration.init;

	foreach (subvolume; srcSubvolumes.keys.sort)
	{
		auto      srcSnapshots = srcSubvolumes[subvolume].keys.sort().release;
		immutable allSnapshots = allSubvolumes[subvolume].keys.sort().release.idup;

		auto snapshotIndexInSrcDir = allSnapshots.map!((snapshot) { auto snapshotSubvolume = snapshot.length ? subvolume ~ "-" ~ snapshot : subvolume; return snapshotSubvolume in srcDir && (snapshotSubvolume ~ ".partial") !in srcDir; }).array;

		stderr.writefln("> Subvolume %s", subvolume);

		// Remove live subvolume
		srcSnapshots = srcSnapshots.filter!(s => s.length > 0).array;

		while (srcSnapshots.length)
		{
			auto snapshotIndexInDstDir = allSnapshots.map!((snapshot) { auto snapshotSubvolume = snapshot.length ? subvolume ~ "-" ~ snapshot : subvolume; return snapshotSubvolume in dstDir && (snapshotSubvolume ~ ".partial") !in dstDir; }).array;

			Tuple!(size_t, "distance", string, "snapshot") findParent(string snapshot)
			{
				auto snapshotIndex = allSnapshots.countUntil(snapshot);
				assert(snapshotIndex >= 0);
				foreach (distance, parentSnapshotIndex; roundRobin(iota(snapshotIndex, allSnapshots.length), iota(0, snapshotIndex).retro).enumerate)
				{
					auto parentSnapshot = allSnapshots[parentSnapshotIndex];
					if (!parentSnapshot.length)
						continue;
					//auto parentSubvolume = subvolume ~ "-" ~ parentSnapshot;
					//debug stderr.writefln(">>> Checking for parent: %s", dstParentPath);
					if (snapshotIndexInSrcDir[parentSnapshotIndex] &&
						snapshotIndexInDstDir[parentSnapshotIndex])
						return typeof(return)(distance, parentSnapshot);
				}
				return typeof(return)(size_t.max - 1, string.init);
			}

			// Find the snapshot closest to an existing one.
			auto snapshotIndex = {
				string bestSnapshot;
				size_t bestDistance = size_t.max;
				auto order = srcSnapshots;
				if (newerFirst)
				{
					order = order.dup;
					order.reverse;
				}
				foreach (snapshot; order)
				{
					auto parent = findParent(snapshot);
					if (bestDistance > parent.distance)
					{
						bestDistance = parent.distance;
						bestSnapshot = snapshot;
					}
					if (bestDistance == 0)
						break;
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

				{
					auto haveSnapshot = snapshotSubvolume in dstDir; // dstPath.exists
					auto haveRsync = snapshotSubvolume ~ ".rsync" in dstDir;
					auto haveDst = haveSnapshot || haveRsync;

					if (snapshotSubvolume ~ ".partial" in dstDir) // flagPath.exists
					{

						if (haveDst)
						{
							if (verbose) stderr.writeln(">>> Acquiring lock...");
							auto flag = Lock(flagPath);

							if (haveSnapshot)
							{
								needSnapshotHeader(); stderr.writeln(">>> Cleaning up partially-received snapshot");
								if (!dryRun)
								{
									btrfs_subvolume_delete(dstPath);
									stderr.writeln(">>>> OK");
								}
							}
							if (haveRsync)
							{
								needSnapshotHeader(); stderr.writeln(">>> Cleaning up partially-rsynced snapshot");
								if (!dryRun)
								{
									btrfs_subvolume_delete(dstPath ~ ".rsync");
									stderr.writeln(">>>> OK");
								}
							}

							if (!dryRun)
							{
								// sync();
								flagPath.remove();
							}
						}
						else
						{
							needSnapshotHeader(); stderr.writeln(">>> Deleting orphan flag file: ", flagPath);
							if (!dryRun)
								flagPath.remove();
						}
					}
					else
					{
						if (haveDst) // dstPath.exists
						{
							if (verbose) stderr.writeln(">>> Already in destination, skipping");
							createMark();
							continue;
						}
					}
				}

				if (markOnly)
				{
					if (verbose) stderr.writeln(">>> --mark-only specified, skipping");
					continue;
				}

				debug assert(!flagPath.exists || dryRun);
				debug assert(!dstPath.exists || dryRun);

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
				if (olderThan && now - creationTime < olderThanDur)
				{
					if (verbose) stderr.writefln(">>> Too new (created %s ago), skipping", now - creationTime);
					continue;
				}
				if (newerThan && now - creationTime > newerThanDur)
				{
					if (verbose) stderr.writefln(">>> Too old (created %s ago), skipping", now - creationTime);
					continue;
				}

				string parentSubvolume;

				void copyBtrfsSendReceive()
				{
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
								stderr.writefln(">>> Error, deleting partially-received subvolume...");
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
						auto recvStatus = recvPid.wait();
						auto sendStatus = sendPid.wait();
						int pvStatus;
						if (pv)
							pvStatus = pvPid.wait();
						enforce(recvStatus == 0, "btrfs-receive failed");
						enforce(sendStatus == 0, "btrfs-send failed");
						enforce(pvStatus == 0, "pv failed");
						enforce(dstPath.exists, "Sent subvolume does not exist: " ~ dstPath);
						if (verbose) stderr.writeln(">>>> OK");
					}
					dstDir.add(snapshotSubvolume);
				}

				void copyRsync()
				{
					dstPath ~= ".rsync";
					snapshotSubvolume ~= ".rsync";

					auto flag = Lock(flagPath);
					// sync();
					scope(exit) flagPath.remove();

					scope(failure)
					{
						if (dstPath.exists)
						{
							stderr.writefln(">>> Error, deleting partially-rsynced subvolume...");
							btrfs_subvolume_delete(dstPath);
							if (verbose) stderr.writefln(">>>> Done.");
						}
					}

					string parentSubvolume; // not the same as used by btrfs - this one need not exist in the source
					{
						bool isSnapshot(string fn) { return fn.indexOf('.') < 0 || fn.endsWith(".rsync"); }
						auto dstSnapshots = dstDir.keys.filter!(fn => fn.startsWith(subvolume ~ "-") && isSnapshot(fn)).array.sort;
						auto lb = dstSnapshots.lowerBound(subvolume ~ "-" ~ snapshot);
						if (!lb.empty)
						{
							parentSubvolume = lb.back;
							if (verbose) stderr.writeln(">>> Found a \"parent\" snapshot to use as rsync base: ", parentSubvolume);
						}
						else
						if (!dstSnapshots.empty)
						{
							parentSubvolume = dstSnapshots.front;
							if (verbose) stderr.writeln(">>> Using first snapshot as rsync base: ", parentSubvolume);
						}
					}
					if (!parentSubvolume)
					{
						enforce(!requireParent, "No parent found, skipping");
						needSnapshotHeader(); stderr.writefln(">>> No parent found, sending whole.");
						string[] args = ["btrfs", "subvolume", "create", dstPath].remotify;
						if (verbose) stderr.writefln(">>> %s", args.escapeShellCommand);
						if (!dryRun) enforce(spawnProcess(args).wait() == 0, "'btrfs subvolume create' failed");
					}
					else
					{
						if (dstPath.exists) assert(false, "Trying to snapshot to existing path");
						auto parentPath = buildPath(dstRoot, parentSubvolume);
						string[] args = ["btrfs", "subvolume", "snapshot", parentPath, dstPath].remotify;
						if (verbose) stderr.writefln(">>> %s", args.escapeShellCommand);
						if (!dryRun) enforce(spawnProcess(args).wait() == 0, "'btrfs subvolume snapshot' failed");
					}

					{
						string[] args = [
							"rsync",
							"--archive", "--hard-links", "--acls", "--xattrs", // copy everything
							"--append-verify", // extend appended files
							"--inplace", // only update changed parts of files (implied by --append-verify)
							"--delete", // delete deleted files
							"--ignore-errors", // ignore errors
						];
						if (dryRun)
							args ~= "--dry-run";
						if (verbose)
						{
							args ~= "--verbose";
							if (pv)
								args ~= "--progress";
						}
						args ~= [
							srcPath.toRsyncPath ~ "/",
							dstPath.toRsyncPath,
						];

						if (verbose) stderr.writefln(">>> %s", args.escapeShellCommand);
						auto rsyncStatus = spawnProcess(args).wait();
						enforce(rsyncStatus.isOneOf(0, 23), "rsync failed (exit status %s)".format(rsyncStatus));
						if (!dryRun)
						{
							enforce(dstPath.exists, "Sent subvolume does not exist: " ~ dstPath);
							if (verbose) stderr.writeln(">>>> OK");
						}
					}

					{
						string[] args = ["btrfs", "property", "set", "-ts", dstPath, "ro", "true"];
						if (verbose) stderr.writefln(">>> %s", args.escapeShellCommand);
						if (!dryRun) enforce(spawnProcess(args).wait() == 0, "'btrfs property set' failed");
					}

					dstDir.add(snapshotSubvolume);
				}

				final switch (rsync)
				{
					case RsyncCondition.never:
						copyBtrfsSendReceive();
						break;
					case RsyncCondition.error:
						try
							copyBtrfsSendReceive();
						catch (Exception e)
						{
							warning = true;
							stderr.writefln(">> Error (%s), falling back to rsync...", e.msg);
							copyRsync();
						}
						break;
					case RsyncCondition.always:
						copyRsync();
						break;
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
			}
			catch (Exception e)
			{
				needSnapshotHeader(); stderr.writefln(">>> Error! %s", e.msg);
				error = true;
			}
		}

		if (createLatestSymlink)
		{
			auto snapshots = allSnapshots.retro.filter!(s => s.length > 0);
			if (!snapshots.empty)
			{
				auto latestSnapshot = snapshots.front;
				auto name = subvolume ~ ".latest";
				auto target = subvolume ~ "-" ~ latestSnapshot;
				stderr.writefln("Creating symlink: %s -> %s", name, target);
				if (!dryRun)
				{
					dstRoot.buildPath(name).remove().collectException();
					symlink(target, dstRoot.buildPath(name));
				}
			}
		}
	}
	if (error)
		stderr.writeln("> Done with some errors.");
	else
	if (warning)
		stderr.writeln("> Done with some warnings.");
	else
		stderr.writeln("> Done with no warnings or errors.");
	return error ? 2 : warning ? 3 : 0;
}

mixin main!(funopt!btrfs_snapshot_archive);
