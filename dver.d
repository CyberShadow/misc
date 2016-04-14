import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.sys.archive;
import ae.sys.file;

enum BASE = `/home/vladimir/Downloads/!dmd/`;

version(linux)
	enum platform = "linux";
else
version(Windows)
	enum platform = "windows";
else
	static assert(false);

int main(string[] args)
{
	bool download, verbose, wine, model32;
	getopt(args,
		config.stopOnFirstNonOption,
		"d|dl", &download,
		"v|verbose", &verbose,
		"wine", &wine,
		"32", &model32,
	);

	enforce(args.length >= 3, "Usage: dver [-d] DVERSION COMMAND [COMMAND-ARGS...]");
	auto dver = args[1];
	auto command = args[2..$];
	auto dir = BASE ~ `dmd.` ~ dver;

	if (!dir.exists)
	{
		if (download)
		{
			string fn;
			if (dver < "2.071.0")
				fn = "dmd.%s.zip".format(dver);
			else
				fn = "dmd.%s.%s.zip".format(dver, platform);
			if (verbose) stderr.writefln("Downloading %s...", fn);
			auto url = "http://downloads.dlang.org/releases/%s.x/%s/%s"
				.format(dver[0], dver, fn);
			auto zip = BASE ~ fn;
			auto ret = spawnProcess(["aget", "--out", zip, url], null, Config.none, "/").wait();
			enforce(ret==0, "Download failed");

			if (verbose) stderr.writefln("Unzipping %s...", fn);
			atomic!unzip(zip, dir);
		}
		else
		{
			if (verbose) stderr.writeln("Directory not found, scanning similar versions...");
			auto dirs = dirEntries(BASE, `dmd.` ~ dver ~ ".*", SpanMode.shallow)
				.filter!(de => de.isDir)
				.map!(de => de.baseName)
				.array
				.sort();
			if (verbose) stderr.writefln("Found versions: ", dirs);
			if (dirs.length)
			{
				auto lastDir = dirs[$-1];
				stderr.writefln("(auto-correcting D version %s to %s)", dver, lastDir[4..$]);
				dir = BASE ~ lastDir;
			}
		}
	}
	enforce(dir.exists, "Directory doesn't exist: " ~ dir);

	string[] binDirs;
	string binExt;

	if (wine)
	{
		binDirs = [`dmd2/windows/bin`, `dmd/windows/bin`, `dmd/bin`];
		binExt = ".exe";
	}
	else
	{
		string model = model32 ? "32" : "64";
		binDirs = [`dmd2/linux/bin` ~ model, `dmd2/linux/bin`, `dmd/linux/bin`, `dmd/bin`];
		binExt = "";
	}

	foreach (binDir; binDirs)
	{
		auto binPath = dir ~ `/` ~ binDir;
		auto dmd = binPath ~ "/dmd" ~ binExt;
		if (dmd.exists)
		{
			if (verbose) stderr.writefln("Found dmd: %s", dmd);
			if (wine)
				command = ["wine"] ~ binPath.buildPath(command[0]) ~ command[1..$];
			else
			{
				auto attributes = dmd.getAttributes();
				if (!(attributes & octal!111))
					dmd.setAttributes((attributes & octal!444) >> 2);
				environment["PATH"] = binPath ~ `:` ~ environment["PATH"];
				if (verbose) stderr.writefln("PATH=%s", environment["PATH"]);
			}
			auto pid = spawnProcess(command);
			return pid.wait();
		}
	}
	throw new Exception("Can't find bin directory under " ~ dir);
}
