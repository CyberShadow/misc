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

import ae.sys.vfs;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.time.parse;
import ae.utils.time.parsedur;

import btrfs_common;

int btrfs_snapshot_cleanup(
	Parameter!(string, "Path to btrfs root directory") root,
	Switch!("Dry run (only pretend to do anything)") dryRun,
	Switch!("Be more verbose") verbose,
	Switch!("Delete partially-transferred snapshots, too") deletePartial,
	Option!(string, "Only consider snapshots matching this glob") mask = null,
	Option!(string, "Do not consider snapshots matching this glob") notMask = null,
	Option!(string[], "Only consider snapshots with all of the given marks", "MARK") mark = null,
	Option!(string, "Only consider snapshots older than this duration", "DUR") olderThan = null,
	Option!(int, "Number of considered snapshots to keep", "COUNT") keep = 2,
	Switch!("Run `btrfs subvolume sync` after every deleted snapshot") sync = false,
	Option!(string, "Delay to sleep after deleting every snapshot", "DUR") sleep = null,
	Option!(float, "Sleep while the system load is above this value", "LOAD") maxLoad = float.nan,
	Option!(int, "Warn when there are over N remaining snapshots", "N") warnLimit = 0,
)
{
	import core.stdc.stdio : setvbuf, _IOLBF;
	setvbuf(stderr.getFP(), null, _IOLBF, 1024);

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

	foreach (subvolume; allSnapshots.keys.sort)
	{
		auto snapshots = allSnapshots[subvolume];
		snapshots.sort();
		stderr.writefln("> Subvolume %s", subvolume);

		if (verbose) stderr.writefln(">> Listing snapshots");
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

				if (mask && !globMatch(snapshotSubvolume, mask))
				{
					if (verbose) stderr.writefln(">>>> Mask mismatch, skipping");
					continue;
				}

				if (notMask && globMatch(snapshotSubvolume, notMask))
				{
					if (verbose) stderr.writefln(">>>> Not-mask match, skipping");
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

				if (verbose) stderr.writeln(">>>> OK, queuing candidate for deletion");
				candidates ~= snapshot;
			}
			catch (Exception e)
			{
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

				if (!dryRun)
				{
					if (verbose) stderr.writeln(">>>> Acquiring lock...");
					auto flag = Lock(flagPath);

					if (verbose) stderr.writefln(">>>> Deleting...");
					btrfs_subvolume_delete(path);
					flagPath.remove();
					if (verbose) stderr.writeln(">>>>> OK");
				}
				else
					if (verbose) stderr.writeln(">>>>> OK (dry-run)");

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
