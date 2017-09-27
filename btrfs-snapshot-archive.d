/// Copy snapshots from one volume to another.
/// Supports remote hosts for source or target (push or pull) using
/// ssh://user@host//path/to/btrfs/root URLs.
module btrfs_snapshot_archive;

import core.sys.posix.unistd;
import core.thread;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.conv;
import std.exception;
import std.path;
import std.process;
import std.range;
import std.stdio : stderr, File;
import std.string;

import ae.sys.file : readFile;
import ae.sys.vfs : exists, remove, listDir, write, touch, VFS, registry;
import ae.utils.aa;
import ae.utils.array;
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

int btrfs_snapshot_archive(
	Parameter!(string, "Path to source btrfs root directory") srcRoot,
	Parameter!(string, "Path to target btrfs root directory") dstRoot,
	Switch!("Dry run (only pretend to do anything)") dryRun,
	Switch!("Delete redundant snapshots from the source afterwards") cleanUp,
	Option!(string, "Leave a file in the source root dir for each successfully copied snapshot, based on the snapshot name and MARK", "MARK") successMark = null,
)
{
	import core.stdc.stdio : setvbuf, _IOLBF;
	setvbuf(stderr.getFP(), null, _IOLBF, 1024);

	string[][string] allSnapshots;

	auto srcDir = srcRoot.listDir.toSet;
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

				void createMark()
				{
					if (successMark)
					{
						auto markPath = srcPath ~ ".success-" ~ successMark;
						if (markPath.baseName !in srcDir)
						{
							stderr.writefln(">>> Creating mark: %s", markPath);
							if (!dryRun)
								touch(markPath);
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
							sync();
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
				assert(!flagPath.exists || dryRun);
				assert(!dstPath.exists || dryRun);

				if (srcPath.buildPath(".nobackup").exists)
				{
					stderr.writeln(">>> Has .nobackup file, skipping");
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

				sendArgs = remotify(sendArgs);
				recvArgs = remotify(recvArgs);

				stderr.writefln(">>> %s | %s", sendArgs.escapeShellCommand, recvArgs.escapeShellCommand);
				if (!dryRun)
				{
					auto flag = Lock(flagPath);
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
					auto sendPid = spawnProcess(sendArgs, File("/dev/null"), sendPipe.writeEnd);
					auto recvPid = spawnProcess(recvArgs, sendPipe.readEnd, stderr);
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
	return error ? 1 : 0;
}

class SSHFS : VFS
{
	override void copy(string from, string to) { assert(false, "Not implemented"); }
	override void rename(string from, string to) { assert(false, "Not implemented"); }
	override void mkdirRecurse(string path) { assert(false, "Not implemented"); }
	override ubyte[16] mdFile(string path) { assert(false, "Not implemented"); }

	override void[] read(string path)
	{
		auto p = pipe();
		auto host = parseHost(path);
		auto pid = spawnProcess(["ssh", host, escapeShellCommand(["cat", "--", path])], File("/dev/null"), p.writeEnd);
		auto data = readFile(p.readEnd);
		pid.wait();
		return data;
	}

	override void write(string path, const(void)[] data)
	{
		auto p = pipe();
		auto host = parseHost(path);
		auto pid = spawnProcess(["ssh", host, escapeShellCommand(["cat"]) ~ " > " ~ escapeShellFileName(path)], p.readEnd, stderr);
		p.writeEnd.rawWrite(data);
		p.writeEnd.close();
		pid.wait();
	}

	override bool exists(string path)
	{
		auto host = parseHost(path);
		path = path.chomp("/");
		auto output = run(["ssh", host, escapeShellCommand(["test", "-e", path]) ~ " && echo -n yes || echo -n no"]);
		if (output == "yes")
			return true;
		else
		if (output == "no")
			return false;
		else
			throw new Exception("Unexpected ssh/test output: " ~ output);
	}

	override string[] listDir(string path)
	{
		auto host = parseHost(path);
		path = path.chomp("/");
		auto output = run(["ssh", host, escapeShellCommand(["find", path, "-maxdepth", "1", "-print0"])]);
		if (output.length)
		{
			enforce(output[$-1] == 0, "Output not null terminated");
			return output[0..$-1]
				.split("\x00")
				.filter!(s => s != path)
				.map!((s) { enforce(s.skipOver(path ~ "/"), "Unexpected path prefix in find output (`%s` does not start with `%s`)".format(s, path ~ "/")); return s; })
				.array();
		}
		else
			return null;
	}

	override void remove(string path)
	{
		auto host = parseHost(path);
		run(["ssh", host, escapeShellCommand(["rm", "--", path])]);
	}

	static this()
	{
		registry["ssh"] = new SSHFS();
	}

	private static string parseHost(ref string path)
	{
		assert(path.skipOver("ssh://"));
		auto parts = path.findSplit("/");
		path = parts[2];
		return parts[0];
	}
}

struct Lock
{
	File f;

	this(string path)
	{
		if (path.startsWith("ssh://"))
		{
			enforce(!path.exists, "Lockfile exists: " ~ path);
			write(path, "");
		}
		else
		{
			f.open(path, "wb");
			enforce(f.tryLock(), "Exclusive locking failed");
		}
	}
}

string[] remotify(string[] args)
{
	foreach (arg; args)
		if (arg.startsWith("ssh://"))
		{
			auto path = arg;
			auto host = SSHFS.parseHost(path);
			return ["ssh", host, escapeShellCommand(
					args.map!((arg)
					{
						if (arg.startsWith("ssh://"))
							enforce(SSHFS.parseHost(arg) == host, "Inconsistent sshfs host");
						return arg;
					}).array)];
		}
	return args;
}

string localPart(string path)
{
	if (path.startsWith("ssh://"))
		SSHFS.parseHost(path);
	return path;
}

string[string] btrfs_subvolume_show(string path)
{
	auto output = run(remotify(["btrfs", "subvolume", "show", path]));

	auto lines = output.splitLines();
	auto acceptedFirstLines = [localPart(path).absolutePath, localPart(path).baseName];
	enforce(lines[0].isIn(acceptedFirstLines),
		"Unexpected btrfs-subvolume-show output: First line is `%s`, expected one of %(`%s`%|, %)"
		.format(lines[0], acceptedFirstLines));

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
	run(remotify(["btrfs", "subvolume", "delete", "-c", path]));
}

string run(string[] args)
{
	import std.stdio : stdin;
	auto p = pipe();
	auto pid = spawnProcess(args, stdin, p.writeEnd);
	auto result = p.readEnd.readFile;
	enforce(pid.wait() == 0, "Command failed: " ~ escapeShellCommand(args));
	return cast(string)result;
}

mixin main!(funopt!btrfs_snapshot_archive);
