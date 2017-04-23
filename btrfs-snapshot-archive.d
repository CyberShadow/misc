/// Copy snapshots from one volume to another.
module btrfs_snapshot_archive;

import core.sys.posix.unistd;
import core.thread;

import std.algorithm.searching;
import std.algorithm.sorting;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.regex;

/*
  - For each subvolume:
    - Find common parent
      - If no common parent, send whole
    - Send (minding parent) + receive (minding parent, to temporary subvolume name)
    - If successful, move temporary subvolume
    - Delete the PARENT subvolume from source

  - TODO:
    - don't use -p, use -c,
    - don't clean up ALL snapshots, leave a few days' worth
      - move cleanup to a separate tool
 */

int btrfs_snapshot_archive(string srcRoot, string dstRoot, bool dryRun, bool cleanUp)
{
	string[][string] allSnapshots;

	foreach (de; dirEntries(srcRoot, SpanMode.shallow))
	{
		auto name = de.baseName;
		enforce(name.startsWith("@"), "Invalid name: " ~ de.name);
		auto parts = name.findSplit("-");
		string time = null;
		if (parts[1].length)
		{
			time = parts[2];
			name = parts[0];
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
				assert(srcPath.exists);
				auto dstPath = buildPath(dstRoot, snapshotSubvolume);
				auto flagPath = dstPath ~ ".partial";
				if (dstPath.exists)
				{
					if (flagPath.exists)
					{
						stderr.writeln(">>> Acquiring lock...");
						auto flag = File(flagPath, "wb");
						enforce(flag.tryLock(), "Exclusive locking failed");

						stderr.writeln(">>> Cleaning up partially-received snapshot");
						if (!dryRun)
						{
							btrfs_subvolume_delete(dstPath);
							sync();
							flagPath.remove();
							stderr.writeln(">>>> OK");
						}
					}
					else
					{
						stderr.writeln(">>> Already in destination, skipping");
						continue;
					}
				}
				else
				{
					if (flagPath.exists)
					{
						stderr.writeln(">>> Deleting orphan flag file: ", flagPath);
						if (!dryRun)
							flagPath.remove();
					}
				}
				assert(!flagPath.exists || dryRun);
				assert(!dstPath.exists || dryRun);

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
					if (dstParentPath.exists)
					{
						stderr.writefln(">>> Found parent: %s", parentSnapshot);
						parent = parentSubvolume;
						break;
					}
				}
				if (!parent)
					stderr.writefln(">>> No parent found, sending whole.");

				auto sendArgs = ["btrfs", "send"];
				if (parent)
				{
					auto srcParentPath = buildPath(srcRoot, parent);
					assert(srcParentPath.exists);
					sendArgs ~= ["-p", srcParentPath];
				}

				sendArgs ~= srcPath;
				auto recvArgs = ["btrfs", "receive", dstRoot];

				stderr.writefln(">>> %-(%s %) | %-(%s %)", sendArgs, recvArgs);
				if (!dryRun)
				{
					auto flag = File(flagPath, "wb");
					enforce(flag.tryLock(), "Exclusive locking failed");
					sync();
					scope(exit) flagPath.remove();

					scope(failure)
					{
						if (dstPath.exists)
						{
							stderr.writefln(">>> Error, deleting partially-sent subvolume...");
							btrfs_subvolume_delete(dstPath);
							sync();
							stderr.writefln(">>>> Done.");
						}
					}
					auto sendPipe = pipe();
					auto sendPid = spawnProcess(sendArgs, stdin, sendPipe.writeEnd);
					auto recvPid = spawnProcess(recvArgs, sendPipe.readEnd);
					enforce(recvPid.wait() == 0, "btrfs-receive failed");
					enforce(sendPid.wait() == 0, "btrfs-send failed");
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
			}
			catch (Exception e)
			{
				stderr.writefln(">>> Error! %s", e.msg);
				error = true;
			}
		}
	}
	return error ? 1 : 0;
}

/*
 */

string[string] btrfs_subvolume_show(string path)
{
	auto btrfs = execute(["btrfs", "subvolume", "show", path]);
	enforce(btrfs.status == 0, "btrfs-subvolume-show failed");

	auto lines = btrfs.output.splitLines();
	enforce(lines[0] == path.absolutePath);

	string[string] result;
	foreach (line; lines[1..$])
	{
		line.matchCaptures(`^\t(.+):(?: \t+(.*))?$`,
			(string name, string value) { result[name] = value; });
	}
	return result;
}

void btrfs_subvolume_delete(string path)
{
	auto btrfs = execute(["btrfs", "subvolume", "delete", "-c", path]);
	enforce(btrfs.status == 0, "btrfs-subvolume-delete failed");
}

mixin main!(funopt!btrfs_snapshot_archive);
