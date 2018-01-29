/// Common code for btrfs-snapshot utilities.
module btrfs_common;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.exception;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.sys.file : readFile;
import ae.sys.vfs : exists, remove, listDir, write, VFS, registry;
import ae.utils.array;
import ae.utils.regex;

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

void btrfs_subvolume_sync(string path)
{
	run(remotify(["btrfs", "subvolume", "sync", path]));
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
