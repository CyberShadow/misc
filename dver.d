import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.file;
import std.getopt : config;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.sys.archive;
import ae.sys.file;

enum BASE = `/home/vladimir/Downloads/!dmd/`;

int dver(
	Switch!("Download versions if not present", 'd') download,
	Switch!("Verbose output", 'v') verbose,
	Switch!("Run via Wine", 'w') wine,
	Switch!("Use 32-bit model", 0, "32") model32,
	Option!(string, "Whether to use a beta release, and which") beta,
	Parameter!(string, "D version to use") dVersion,
	Parameter!(string, "Program to execute") program,
	Parameter!(string[], "Program arguments") args = null,
)
{
	auto command = [program.value] ~ args.value;

	string baseVersion = dVersion;
	if (beta)
		dVersion ~= "-b" ~ beta;

	string platform;
	if (wine)
		platform = "windows";
	else
	{
		version(linux)
			platform = "linux";
		else
		version(Windows)
			platform = "windows";
		else
			static assert(false);
	}

	string platformSuffix = baseVersion < "2.071.0" ? "" : "." ~ platform;
	auto dir = BASE ~ "dmd." ~ dVersion ~ platformSuffix;

	string model = model32 ? "32" : "64";
	string[] binDirs = [`dmd2/` ~ platform ~ `/bin` ~ model, `dmd2/` ~ platform ~ `/bin`, `dmd/` ~ platform ~ `/bin`, `dmd/bin`];
	string binExt = platform == "windows" ? ".exe" : "";

	bool found;
	if (dir.exists)
	{
		foreach (binDir; binDirs)
		{
			auto binPath = dir ~ `/` ~ binDir;
			auto dmd = binPath ~ "/dmd" ~ binExt;
			if (dmd.exists)
			{
				if (verbose) stderr.writefln("Found dmd: %s", dmd);
				found = true;
				break;
			}
		}
	}

	if (!found)
	{
		if (download)
		{
			string fn = "dmd." ~ dVersion ~ platformSuffix ~ ".zip";
			if (verbose) stderr.writefln("Downloading %s...", fn);
			auto url = "http://downloads.dlang.org/%sreleases/%s.x/%s/%s".format(
				beta ? "pre-" : "",
				baseVersion[0],
				baseVersion,
				fn,
			);
			auto zip = BASE ~ fn;
			auto ret = spawnProcess(["aget", "--out", zip, url], null, Config.none, "/").wait();
			enforce(ret==0, "Download failed");

			if (verbose) stderr.writefln("Unzipping %s...", fn);
			atomic!unzip(zip, dir);
			found = true;
		}
		else
		{
			if (verbose) stderr.writeln("Directory not found, scanning similar versions...");
			auto dirs = dirEntries(BASE, `dmd.` ~ dVersion ~ ".*" ~ platformSuffix, SpanMode.shallow)
				.filter!(de => de.isDir)
				.map!(de => de.baseName.chomp(platformSuffix))
				.array
				.sort();
			if (verbose) stderr.writefln("Found versions: ", dirs);
			if (dirs.length)
			{
				auto lastDir = dirs[$-1];
				stderr.writefln("(auto-correcting D version %s to %s)", dVersion, lastDir[4..$]);
				dir = BASE ~ lastDir ~ platformSuffix;
				found = true;
			}
		}
	}
	enforce(found, "Can't find this D version.");

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
static import std.getopt;

const FunOptConfig funoptConfig = { getoptConfig : [ std.getopt.config.stopOnFirstNonOption ] };
mixin main!(funopt!(dver, funoptConfig));
