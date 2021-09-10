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
		auto args = parsePath(path);
		auto pid = spawnProcess(["ssh"] ~ args ~ [escapeShellCommand(["cat", "--", path])], File("/dev/null"), p.writeEnd);
		auto data = readFile(p.readEnd);
		pid.wait();
		return data;
	}

	override void write(string path, const(void)[] data)
	{
		auto p = pipe();
		auto args = parsePath(path);
		auto pid = spawnProcess(["ssh"] ~ args ~ [escapeShellCommand(["cat"]) ~ " > " ~ escapeShellFileName(path)], p.readEnd, stderr);
		p.writeEnd.rawWrite(data);
		p.writeEnd.close();
		pid.wait();
	}

	override bool exists(string path)
	{
		auto args = parsePath(path);
		path = path.chomp("/");
		auto output = run(["ssh"] ~ args ~ [escapeShellCommand(["test", "-e", path]) ~ " && echo -n yes || echo -n no"]);
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
		auto args = parsePath(path);
		path = path.chomp("/");
		auto output = run(["ssh"] ~ args ~ [escapeShellCommand(["find", path, "-maxdepth", "1", "-print0"])]);
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
		auto args = parsePath(path);
		run(["ssh"] ~ args ~ [escapeShellCommand(["rm", "--", path])]);
	}

	override void rmdirRecurse(string path)
	{
		auto args = parsePath(path);
		run(["ssh"] ~ args ~ [escapeShellCommand(["rm", "-rf", "--", path])]);
	}

	override void symlink(string from, string to)
	{
		auto args = parsePath(to);
		run(["ssh"] ~ args ~ [escapeShellCommand(["ln", "-s", "--", from, to])]);
	}

	static this()
	{
		registry["ssh"] = new SSHFS();
	}

	/// Extract and convert hostname/port from VFS path to ssh command-line parameters.
	private static string[] parsePath(ref string path)
	{
		assert(path.skipOver("ssh://"));
		auto parts = path.findSplit("/");
		path = parts[2];
		auto host = parts[0];
		parts = host.findSplit(":");
		auto args = [parts[0]];
		if (parts[1].length)
			args ~= ["-p", parts[2]];
		return args;
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
			auto pathArgs = SSHFS.parsePath(path);
			return ["ssh"] ~ pathArgs ~ [escapeShellCommand(
					args.map!((arg)
					{
						if (arg.startsWith("ssh://"))
							enforce(SSHFS.parsePath(arg) == pathArgs, "Inconsistent sshfs root");
						return arg;
					}).array)];
		}
	return args;
}

string toRsyncPath(string path)
{
	if (path.startsWith("ssh://"))
	{
		auto args = SSHFS.parsePath(path);
		enforce(args.length == 1, "Can't use SSH options (port) with Rsync");
		auto host = args[0];
		enforce(path.isAbsolute,
			"Using non-absolute paths via ssh is dangerous " ~
			"(did you mean ssh://host//path instead of ssh://host/path?): " ~ path);
		return host ~ ":" ~ path;
	}
	else
		return path;
}

string localPart(string path)
{
	if (path.startsWith("ssh://"))
		SSHFS.parsePath(path);
	return path;
}

string[string] btrfs_subvolume_show(string path)
{
	auto output = run(remotify(["btrfs", "subvolume", "show", path]));

	auto lines = output.splitLines();
	enforce(lines[0] == localPart(path).absolutePath || lines[0].endsWith(localPart(path).baseName),
		"Unexpected btrfs-subvolume-show output: First line is `%s`, expected absolute or root-relative of `%s`"
		.format(lines[0], localPart(path)));

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
