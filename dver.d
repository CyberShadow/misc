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

int dver(
	Switch!("Download versions if not present", 'd') download,
	Switch!("Verbose output", 'v') verbose,
	Switch!("Run via Wine", 'w') wine,
	Switch!("Use 32-bit model", 0, "32") model32,
	Parameter!(string, "D version to use") dVersion,
	Parameter!(string[], "Command to execute") command,
)
{
	auto dir = BASE ~ `dmd.` ~ dVersion;

	if (!dir.exists)
	{
		if (download)
		{
			string fn;
			if (dVersion < "2.071.0")
				fn = "dmd.%s.zip".format(dVersion);
			else
				fn = "dmd.%s.%s.zip".format(dVersion, platform);
			if (verbose) stderr.writefln("Downloading %s...", fn);
			auto url = "http://downloads.dlang.org/releases/%s.x/%s/%s"
				.format(dVersion[0], dVersion, fn);
			auto zip = BASE ~ fn;
			auto ret = spawnProcess(["aget", "--out", zip, url], null, Config.none, "/").wait();
			enforce(ret==0, "Download failed");

			if (verbose) stderr.writefln("Unzipping %s...", fn);
			atomic!unzip(zip, dir);
		}
		else
		{
			if (verbose) stderr.writeln("Directory not found, scanning similar versions...");
			auto dirs = dirEntries(BASE, `dmd.` ~ dVersion ~ ".*", SpanMode.shallow)
				.filter!(de => de.isDir)
				.map!(de => de.baseName)
				.array
				.sort();
			if (verbose) stderr.writefln("Found versions: ", dirs);
			if (dirs.length)
			{
				auto lastDir = dirs[$-1];
				stderr.writefln("(auto-correcting D version %s to %s)", dVersion, lastDir[4..$]);
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

import ae.utils.main;
import ae.utils.funopt;

mixin main!(funopt!dver);
