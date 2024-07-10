#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
 dflags "-i"  # https://github.com/dlang/dub/issues/2638
 stringImportPaths "."
+/

/// Clean up older snapshots, as backed up by btrfs-snapshot-archive.
module btrfs_snapshot_cleanup;

import core.thread;
import core.time;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.conv;
import std.datetime;
import std.math : isNaN;
import std.path;
import std.stdio : stderr, File;
import std.string;

import ae.sys.vfs;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.time.fpdur;
import ae.utils.time.parse;
import ae.utils.time.parsedur;

import btrfs_common;

int btrfs_snapshot_cleanup(
	Parameter!(string, "Path to btrfs root directory") root,
	Switch!("Dry run (only pretend to do anything)") dryRun,
	Switch!("Be more verbose") verbose,
	Switch!("Delete partially-transferred snapshots, too") deletePartial,
	Switch!("Delete orphan success marks, too") cleanMarks,
	Option!(string[], "Only consider snapshots matching this glob") mask = null,
	Option!(string[], "Do not consider snapshots matching this glob") notMask = null,
	Option!(string[], "Only consider snapshots with all of the given marks", "MARK") mark = null,
	Option!(string, "Only consider snapshots which do not exist at this location", "DIR") notIn = null,
	Option!(string, "Only consider snapshots which also exist at this location", "DIR") alsoIn = null,
	Option!(string, "Only consider snapshots older than this duration", "DUR") olderThan = null,
	Switch!("Only consider snapshots older than the current uptime") olderThanBoot = false,
	Option!(int, "Number of considered snapshots to keep", "COUNT") keep = 2,
	Switch!("Run `btrfs subvolume sync` after every deleted snapshot") sync = false,
	Option!(string, "Delay to sleep after deleting every snapshot", "DUR") sleep = null,
	Option!(float, "Sleep while the system load is above this value", "LOAD") maxLoad = float.nan,
	Option!(int, "Warn when there are over N remaining snapshots", "N") warnLimit = 0,
)
{
	import core.stdc.stdio : _IOLBF;
	stderr.setvbuf(1024, _IOLBF);

	string[][string] allSnapshots;

	stderr.writefln("> Enumerating %s", root);
	auto dir = root.listDir.toSet;

	foreach (name; dir.byKey)
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
			//if (verbose) stderr.writeln("Flag file, skipping: " ~ name);
			continue;
		}
		allSnapshots[name] ~= time;
	}

	bool error, warning;
	auto now = Clock.currTime;
	auto olderThanDur = olderThan ? olderThan.parseDuration : Duration.init;
	auto sleepDur = sleep ? sleep.parseDuration : Duration.init;
	SysTime bootTime;
	if (olderThanBoot)
		bootTime = Clock.currTime() - "/proc/uptime".readText.split[0].to!real.seconds;

	foreach (subvolume; allSnapshots.keys.sort)
	{
		auto snapshots = allSnapshots[subvolume];
		snapshots.sort();
		stderr.writefln("> Subvolume %s", subvolume);

		stderr.writefln(">> Listing snapshots");
		string[] candidates;

	snapshotLoop:
		foreach (snapshot; snapshots)
		{
			if (!snapshot.length)
				continue; // live subvolume
			if (verbose) stderr.writefln(">>> Snapshot %s", snapshot);

			try
			{
				auto snapshotSubvolume = subvolume ~ "-" ~ snapshot;
				auto path = buildPath(root, snapshotSubvolume);
				assert(snapshotSubvolume in dir); //assert(srcPath.exists);
				auto flagPath = path ~ ".partial";
				bool isPartial = flagPath.exists;

				if (isPartial && !deletePartial)
				{
					if (verbose) stderr.writefln(">>>> Partially-transferred snapshot and --delete-partial not specified, skipping");
					continue;
				}

				if (mask.length && !mask.any!(m => globMatch(snapshotSubvolume, m)))
				{
					if (verbose) stderr.writefln(">>>> Mask mismatch, skipping");
					continue;
				}

				if (notMask.any!(m => globMatch(snapshotSubvolume, m)))
				{
					if (verbose) stderr.writefln(">>>> Not-mask match, skipping");
					continue;
				}

				if (notIn && notIn.buildPath(snapshotSubvolume).exists)
				{
					if (verbose) stderr.writefln(">>>> %s exists, skipping", notIn.buildPath(snapshotSubvolume));
					continue;
				}

				if (alsoIn && !alsoIn.buildPath(snapshotSubvolume).exists)
				{
					if (verbose) stderr.writefln(">>>> %s does not exist, skipping", alsoIn.buildPath(snapshotSubvolume));
					continue;
				}

				foreach (successMark; mark)
				{
					auto markPath = path ~ ".success-" ~ successMark;
					if (markPath.baseName !in dir)
					{
						if (verbose) stderr.writefln(">>>> No %s success mark, skipping", successMark);
						continue snapshotLoop;
					}
				}

				auto info = btrfs_subvolume_show(path);
				if (!isPartial && !info["Flags"].split(" ").canFind("readonly"))
				{
					if (verbose) stderr.writeln(">>>> Not readonly, skipping");
					continue;
				}

				auto creationTime = info["Creation time"].parseTime!`Y-m-d H:i:s O`;

				if (olderThan && now - creationTime < olderThanDur)
				{
					if (verbose) stderr.writefln(">>>> Too new (created %s ago), skipping", now - creationTime);
					continue;
				}

				if (olderThanBoot && creationTime > bootTime)
				{
					if (verbose) stderr.writefln(">>>> Too new (created %s after last boot), skipping", creationTime - bootTime);
					continue;
				}

				if (verbose) stderr.writeln(">>>> OK, queuing candidate for deletion");
				candidates ~= snapshot;
			}
			catch (Exception e)
			{
				if (!verbose) stderr.writefln(">>> Snapshot %s", snapshot);
				stderr.writefln(">>>> Error! %s", e.msg);
				error = true;
			}
		}

		auto toDelete = max(sizediff_t(candidates.length - keep), 0);
		auto toKeep = candidates.length - toDelete;
		if (verbose || toDelete) stderr.writefln(">> %d candidates found; want to keep %d, so keeping %d and deleting %d", candidates.length, keep, toKeep, toDelete);
		candidates = candidates[0..toDelete]; // delete oldest, keep newest

		foreach (snapshot; candidates)
		{
			stderr.writefln(">>> Snapshot %s", snapshot);
			try
			{
				auto snapshotSubvolume = subvolume ~ "-" ~ snapshot;
				auto path = buildPath(root, snapshotSubvolume);
				auto flagPath = path ~ ".partial";

				if (!maxLoad.value.isNaN)
				{
					while (true)
					{
						auto loadStr = "/proc/loadavg".readText().split()[0];
						auto load = loadStr.to!float;
						if (load > maxLoad)
						{
							if (verbose) stderr.writefln(">>>> Load too high (%s > %s), waiting...", loadStr, maxLoad);
							Thread.sleep(30.seconds);
						}
						else
						{
							if (verbose) stderr.writefln(">>>> Load OK (%s < %s)", loadStr, maxLoad);
							break;
						}
					}
				}

				{
					Lock flag;
					if (!dryRun)
					{
						if (verbose) stderr.writeln(">>>> Acquiring lock...");
						flag = Lock(flagPath);
					}

					if (verbose) stderr.writefln(">>>> Deleting...");
					if (!dryRun)
					{
						btrfs_subvolume_delete(path);
						flagPath.remove();
						if (verbose) stderr.writeln(">>>>> OK");
					}
					else
						if (verbose) stderr.writeln(">>>>> OK (dry-run)");

					foreach (fn; dir)
					{
						auto markName = fn[];
						if (markName.skipOver(snapshotSubvolume ~ ".success-"))
						{
							stderr.writefln(">>>> Deleting success mark %s ...", markName);
							if (!dryRun)
							{
								buildPath(root, fn).remove();
								if (verbose) stderr.writeln(">>>>> OK");
							}
							else
								if (verbose) stderr.writeln(">>>>> OK (dry-run)");
						}
					}
				}

				if (sync)
				{
					if (verbose) stderr.writeln(">>>> Syncing...");
					if (!dryRun)
					{
						btrfs_subvolume_sync(root);
						if (verbose) stderr.writeln(">>>>> OK");
					}
					else
						if (verbose) stderr.writeln(">>>>> OK (dry-run)");
				}

				if (sleep)
				{
					if (verbose) stderr.writeln(">>>> Sleeping...");
					Thread.sleep(sleepDur);
					if (verbose) stderr.writeln(">>>>> OK");
				}
			}
			catch (Exception e)
			{
				stderr.writefln(">>>> Error! %s", e.msg);
				error = true;
			}
		}

		if (warnLimit && toKeep > warnLimit)
		{
			stderr.writefln(">> Warning: Too many %s snapshots (%d)", subvolume, toKeep);
			warning = true;
		}
	}

	if (cleanMarks)
	{
		stderr.writeln("> Cleaning up orphan marks...");
		foreach (fn; dir.keys.sort)
		{
			auto p = fn.indexOf(".success-");
			if (p > 0 && fn[0..p] !in dir)
			{
				stderr.writeln(">> ", fn);
				if (!dryRun)
				{
					buildPath(root, fn).remove();
					stderr.writeln(">>> OK");
				}
				else
					stderr.writeln(">>> OK (dry-run)");
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

mixin main!(funopt!btrfs_snapshot_cleanup);
