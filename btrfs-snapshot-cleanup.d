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
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.math : isNaN;
import std.path;
import std.process : escapeShellFileName;
import std.regex : ctRegex, matchFirst;
import std.socket : Socket;
import std.stdio : stderr, stdout, File;
import std.string;

import ae.sys.vfs;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.time.fpdur;
import ae.utils.time.parse;
import ae.utils.time.parsedur;

import btrfs_common;

/// If `fn` is a file belonging to a snapshot (a success mark or a
/// metadata sidecar), return the snapshot's name; otherwise, null.
string ownerSnapshot(string fn)
{
	auto p = fn.indexOf(".success-");
	if (p > 0)
		return fn[0..p];
	if (fn.endsWith(".json"))
		return fn[0..$-".json".length];
	return null;
}

/// Quote `arg` for a POSIX shell, leaving it as-is if it is safe.
string shellQuote(string arg)
{
	if (arg.matchFirst(ctRegex!`^[A-Za-z0-9@%+=:,./_-]+$`))
		return arg;
	return escapeShellFileName(arg);
}

/// Collects commands for deleting copies of snapshots, as recorded
/// in success marks by btrfs-snapshot-archive.
struct CopyDeletionCommands
{
	/// ssh arguments (space-separated; empty for this host) -> paths of copies.
	private string[][string] copies;
	/// Success marks whose copy location was not recorded.
	private string[] unknown;

	/// `location` is the contents of the success mark `markName`.
	void add(string markName, string location)
	{
		if (!location.length)
		{
			unknown ~= markName;
			return;
		}
		auto path = location;
		auto sshArgs = SSHFS.parsePath(path);
		enforce(path.isAbsolute, "Relative path in success mark " ~ markName ~ ": " ~ location);
		if (sshArgs == [Socket.hostName])
			sshArgs = null;
		copies[sshArgs.join(" ")] ~= path;
	}

	/// Write the commands as a shell script snippet.
	void print(File f)
	{
		if (!copies.length && !unknown.length)
			return;
		f.writeln("# To also delete copies of the deleted snapshots, run:");
		foreach (host; copies.keys.sort)
		{
			auto sshArgs = host.split(" ");
			auto paths = copies[host];
			foreach (command; [
				["btrfs", "subvolume", "delete", "-c"] ~ paths,
				["rm", "-f"] ~ paths.map!(path => path ~ ".json").array,
			])
			{
				if (!sshArgs.length || !sshArgs[0].startsWith("root@"))
					command = "sudo" ~ command;
				auto words = command.map!shellQuote.array;
				if (sshArgs.length)
					words = (["ssh"] ~ sshArgs ~ words).map!shellQuote.array; // ssh passes words to the remote shell
				f.writeln(words.join(" "));
			}
		}
		foreach (markName; unknown)
			f.writefln("# %s: unknown destination", markName);
	}
}

unittest
{
	CopyDeletionCommands c;
	c.add("@a-1.success-x", "ssh://" ~ Socket.hostName ~ "//mnt/snaps/@a-1");
	c.add("@a-1.success-y", "ssh://root@remote:2222//mnt/my snaps/@a-1");
	c.add("@a-2.success-y", "ssh://root@remote:2222//mnt/my snaps/@a-2");
	c.add("@a-1.success-z", "ssh://user@remote//mnt/snaps/@a-1");
	c.add("@a-1.success-w", "");
	auto f = File.tmpfile();
	c.print(f);
	f.rewind();
	auto lines = f.byLineCopy.array;
	assert(lines == [
		"# To also delete copies of the deleted snapshots, run:",
		"sudo btrfs subvolume delete -c /mnt/snaps/@a-1",
		"sudo rm -f /mnt/snaps/@a-1.json",
		`ssh root@remote -p 2222 btrfs subvolume delete -c ''\''/mnt/my snaps/@a-1'\''' ''\''/mnt/my snaps/@a-2'\'''`,
		`ssh root@remote -p 2222 rm -f ''\''/mnt/my snaps/@a-1.json'\''' ''\''/mnt/my snaps/@a-2.json'\'''`,
		"ssh user@remote sudo btrfs subvolume delete -c /mnt/snaps/@a-1",
		"ssh user@remote sudo rm -f /mnt/snaps/@a-1.json",
		"# @a-1.success-w: unknown destination",
	], lines.join("\n"));
}

unittest
{
	assert(ownerSnapshot("@home-2026-09-24T00:00:00Z.success-backup") == "@home-2026-09-24T00:00:00Z");
	assert(ownerSnapshot("@home-2026-09-24T00:00:00Z.json") == "@home-2026-09-24T00:00:00Z");
	assert(ownerSnapshot("@home-2026-09-24T00:00:00Z.partial") is null);
	assert(ownerSnapshot("@home-2026-09-24T00:00:00Z") is null);
}

int btrfs_snapshot_cleanup(
	Parameter!(string, "Path to btrfs root directory") root,
	Switch!("Dry run (only pretend to do anything)") dryRun,
	Switch!("Be more verbose") verbose,
	Switch!("Delete partially-transferred snapshots, too") deletePartial,
	Switch!("Delete orphan success marks and metadata sidecars, too") cleanMarks,
	Switch!("Print commands for deleting the copies of deleted snapshots recorded in their success marks") showCopies,
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
	CopyDeletionCommands copies;
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
						if (fn.ownerSnapshot == snapshotSubvolume)
						{
							if (showCopies && fn.canFind(".success-"))
								copies.add(fn, buildPath(root, fn).readText);
							stderr.writefln(">>>> Deleting %s ...", fn);
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
		stderr.writeln("> Cleaning up orphan marks and sidecars...");
		foreach (fn; dir.keys.sort)
		{
			auto owner = fn.ownerSnapshot;
			if (owner.length && owner !in dir)
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

	if (showCopies)
		copies.print(stdout);

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
