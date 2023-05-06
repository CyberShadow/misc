/**
   Run a command against an arbitrary version of D.
*/

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
import ae.utils.meta : I;

version (Windows)
	enum BASE = `C:\Downloads\!dmd\`;
else
	enum BASE = `/home/vladimir/data/software/dmd/`;

version (Posix) import core.sys.posix.sys.stat;

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
	else
	if (dVersion.value.canFind("-b"))
	{
		auto parts = dVersion.value.findSplit("-b");
		baseVersion = parts[0];
		beta = parts[2];
	}

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
	string[] binDirs = [
		`dmd2/` ~ platform ~ `/bin` ~ model,
		`dmd2/` ~ platform ~ `/bin`,
		`dmd/` ~ platform ~ `/bin` ~ model,
		`dmd/` ~ platform ~ `/bin`,
		`dmd/bin`,
	];
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
				if (verbose) stderr.writefln("dver: Found dmd: %s", dmd);
				found = true;
				break;
			}
		}
		enforce(found, "Directory exists but did not find DMD binary: " ~ dir);
	}

	if (!found)
	{
		if (download)
		{
			string fn, url;
			if (baseVersion.startsWith("0."))
			{
				fn = "dmd.%s.zip".format(
					baseVersion[2 .. $],
				);
				url = "http://ftp.digitalmars.com/%s".format(
					fn,
				);
			}
			else
			{
				fn = "dmd." ~ dVersion ~ platformSuffix ~ ".zip";
				url = "http://downloads.dlang.org/%sreleases/%s.x/%s/%s".format(
					beta ? "pre-" : "",
					baseVersion[0],
					baseVersion,
					fn,
				);
			}
			if (verbose) stderr.writefln("dver: Downloading %s...", fn);
			auto zip = BASE ~ fn;
			zip.cached!((string target) {
				auto ret = spawnProcess([
					"aria2c",
					"--max-connection-per-server=16",
					"--split=16",
					"--min-split-size=1M",
					"--dir", target.dirName,
					"-o", target.baseName,
					url
				], null, Config.none, "/").wait();
				enforce(ret == 0, "Download failed");
			});

			if (verbose) stderr.writefln("dver: Unzipping %s...", fn);
			atomic!unzip(zip, dir);
			found = true;
		}
		else
		{
			if (verbose) stderr.writeln("dver: Directory not found, scanning similar versions...");
			auto dirs = dirEntries(BASE, `dmd.` ~ dVersion ~ ".*" ~ platformSuffix, SpanMode.shallow)
				.filter!(de => de.isDir)
				.map!(de => de.baseName.chomp(platformSuffix))
				.array
				.sort();
			if (verbose) stderr.writefln("dver: Found versions: ", dirs);
			if (dirs.length)
			{
				auto lastDir = dirs[$-1];
				stderr.writefln("dver: (auto-correcting D version %s to %s)", dVersion, lastDir[4..$]);
				dir = BASE ~ lastDir ~ platformSuffix;
				found = true;
			}
		}
	}
	enforce(found, "Can't find this D version.");

	// Tell-tale to detect the bin directory we want:
	auto progBin = program.among("dmd", "rdmd", "dub") ? program : "dmd";

	foreach (binDir; binDirs)
	{
		auto binPath = dir ~ `/` ~ binDir;
		auto progPath = binPath ~ `/` ~ progBin ~ binExt;
		if (progPath.exists)
		{
			if (verbose) stderr.writefln("dver: Found %s: %s", progBin, progPath);
			auto confPath = binPath.buildPath("dmd.conf");
			auto suffix1 = "\r\n; added by dver\r\nDFLAGS=-I%@P%/../src/phobos -L-L%@P%/../lib\r\n";
			version (linux)
				if (confPath.exists && confPath.readText.I!(s => s.endsWith("\r\nDFLAGS=-I/home/wgb/yourname/dmd/src/phobos\r\n") || s.endsWith(suffix1)))
				{
					stderr.writeln("dver: Patching ", confPath);
					auto suffix = suffix1.replace("%@P%", binPath); // %@P% support in dmd.conf was added cca D 0.115
					confPath.File("a").write(suffix);
					// Note: really old versions also need -m32 on gcc's command line - can't do that from dmd.conf or dmd's command line, need gcc wrapper
				}
			version (Posix)
			{
				auto dmdAttrs = progPath.getAttributes;
				if (!(dmdAttrs & S_IRUSR))
				{
					stderr.writefln("dver: Making %s readable", progBin);
					progPath.setAttributes(dmdAttrs | S_IRUSR);
				}
			}

			if (wine)
			{
				auto exePath = binPath.buildPath(command[0]);
				if (!exePath.exists && exePath.extension.length == 0 && exePath.setExtension(".exe").exists)
				{
					if (verbose) stderr.writeln("Adding .exe suffix to executable path: " ~ exePath);
					exePath = exePath.setExtension(".exe");
				}

				command = ["wine"] ~ exePath ~ command[1..$];
			}
			else
			{
				auto attributes = progPath.getAttributes();
				if (!(attributes & octal!111))
					progPath.setAttributes((attributes & octal!444) >> 2);
				environment["PATH"] = binPath ~ pathSeparator ~ environment["PATH"];
				if (verbose) stderr.writefln("dver: PATH=%s", environment["PATH"]);
			}
			version (Posix)
				if ("/etc/dmd.conf".exists && confPath.exists)
					command = [
						"bwrap",
						"--dev-bind", "/", "/",
						"--bind", binPath ~ "/dmd.conf", "/etc/dmd.conf",
					] ~ command;
			if (verbose) stderr.writefln("dver: Running %s", command);
			version (Windows)
				return spawnProcess(command).wait();
			else
			{
				execvp(command[0], command);
				errnoEnforce(false, "execvp failed");
			}
		}
		else
			if (verbose) stderr.writefln("dver: Not found, skipping directory: %s", progPath);
	}
	throw new Exception("Can't find bin directory under " ~ dir);
}

import ae.utils.main;
import ae.utils.funopt;
static import std.getopt;

const FunOptConfig funoptConfig = { getoptConfig : [ std.getopt.config.stopOnFirstNonOption ] };
mixin main!(funopt!(dver, funoptConfig));
