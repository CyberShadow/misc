#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3432"
+/

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

version (Posix) import core.sys.posix.sys.stat;

enum Compiler
{
	dmd,
	ldc,
}

int dver(
	Switch!("Download versions if not present", 'd') download,
	Switch!("Verbose output", 'v') verbose,
	Switch!("Run via Wine", 'w') wine,
	Switch!("Use 32-bit model", 0, "32") model32,
	Option!(string, "Whether to use a beta release, and which") beta,
	Option!(Compiler, "Compiler") compiler/* = Compiler.dmd*/,
	Parameter!(string, "D version to use") dVersion,
	Parameter!(string, "Program to execute") program,
	Parameter!(string[], "Program arguments") args = null,
)
{
	auto command = [program.value] ~ args.value;

	auto downloadDir = environment.get("DMD_DOWNLOAD_DIR", null)
		.enforce("Please set the environment variable DMD_DOWNLOAD_DIR to " ~
			"the location where D versions should be downloaded and unpacked."
		);

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
	string binExt = platform == "windows" ? ".exe" : "";

	string fn, dir, url, platformSuffix, majorVersionMask;
	string compilerExecutable;
	string[] binDirs;
	string[] srcDirs;
	final switch (compiler)
	{
		case Compiler.dmd:
			compilerExecutable = "dmd";
			auto base = "dmd." ~ dVersion;
			platformSuffix = baseVersion < "2.071.0" ? "" : "." ~ platform;
			dir = downloadDir.buildPath(base ~ platformSuffix);
			majorVersionMask = base ~ ".*";

			string model = model32 ? "32" : "64";
			binDirs = [
				`dmd2/` ~ platform ~ `/bin` ~ model,
				`dmd2/` ~ platform ~ `/bin`,
				`dmd/` ~ platform ~ `/bin` ~ model,
				`dmd/` ~ platform ~ `/bin`,
				`dmd/bin`,
			];
			srcDirs = [
				`dmd/src`,
				`dmd2/src`,
			];

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
				fn = base ~ platformSuffix ~ ".zip";
				url = "http://downloads.dlang.org/%sreleases/%s.x/%s/%s".format(
					beta ? "pre-" : "",
					baseVersion[0],
					baseVersion,
					fn,
				);
			}
			break;

		case Compiler.ldc:
			compilerExecutable = "ldc2";
			auto base = "ldc2-" ~ dVersion;
			majorVersionMask = base ~ "-*";
			auto os = platform;
			auto arch =
				os == "windows" ? (
					model32 ? "x86" : "x64"
				) :
				os == "linux" ? (
					model32 ? null : "x86_64"
				) : null;
			enforce(arch, "Can't target this compiler/OS/model");
			auto model = model32 ? "32" : "64";

			platformSuffix = "-" ~ os ~ "-" ~ arch;
			auto ext = platform == "windows" ? ".7z" : ".tar.xz";
			if (platform == "windows" && dVersion.value.split(".").map!(to!int).array < [1, 7])
			{
				platformSuffix = "-win" ~ model ~ "-msvc";
				ext = ".zip";
			}
			dir = downloadDir.buildPath(base ~ platformSuffix);
			fn = base ~ platformSuffix ~ ext;
			url = "https://github.com/ldc-developers/ldc/releases/download/v%s/%s".format(dVersion, fn);

			binDirs = [
				base ~ platformSuffix ~ "/bin",
			];
			srcDirs = [
				base ~ platformSuffix ~ "/import",
			];
			break;
	}

	bool found;
	if (dir.exists)
	{
		foreach (binDir; binDirs)
		{
			auto binPath = dir ~ `/` ~ binDir;
			auto executablePath = binPath ~ "/" ~ compilerExecutable ~ binExt;
			if (executablePath.exists)
			{
				if (verbose) stderr.writefln("dver: Found %s: %s", compilerExecutable, executablePath);
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
			if (verbose) stderr.writefln("dver: Downloading %s...", fn);
			auto zip = downloadDir.buildPath(fn);
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
			atomic!unpack(zip, dir);
			found = true;
		}
		else
		{
			if (verbose) stderr.writeln("dver: Directory not found, scanning similar versions...");
			auto dirs = dirEntries(downloadDir, majorVersionMask ~ platformSuffix, SpanMode.shallow)
				.filter!(de => de.isDir)
				.map!(de => de.baseName.chomp(platformSuffix))
				.array
				.sort();
			if (verbose) stderr.writefln("dver: Found versions: ", dirs);
			if (dirs.length)
			{
				auto lastDir = dirs[$-1];
				stderr.writefln("dver: (auto-correcting D version %s to %s)", dVersion, lastDir[4..$]);
				dir = downloadDir.buildPath(lastDir ~ platformSuffix);
				found = true;
			}
		}
	}
	enforce(found, "Can't find this D version.");

	while (!srcDirs.empty && !exists(dir.buildPath(srcDirs.front)))
		srcDirs.popFront();
	enforce(!srcDirs.empty, "Can't find src dir in: " ~ dir);
	string srcDir = srcDirs.front;

	// Tell-tale to detect the bin directory we want:
	auto progBin = program.among(compilerExecutable, "rdmd", "dub") ? program : compilerExecutable;

	foreach (binDir; binDirs)
	{
		auto binPath = dir ~ `/` ~ binDir;
		auto progPath = binPath ~ `/` ~ progBin ~ binExt;
		if (progPath.exists)
		{
			if (verbose) stderr.writefln("dver: Found %s: %s", progBin, progPath);
			auto confPath = binPath.buildPath("dmd.conf");
			auto relSrcPath = relativePath(dir.buildPath(srcDir), binPath);
			auto suffix1 = "\r\n; added by dver\r\nDFLAGS=-I%@P%/../src/phobos -L-L%@P%/../lib\r\n";
			version (linux)
				if (confPath.exists && confPath.readText.I!(s => s.endsWith("\r\nDFLAGS=-I/home/wgb/yourname/dmd/src/phobos\r\n") || s.endsWith(suffix1)))
				{
					stderr.writeln("dver: Patching ", confPath);
					auto suffix = "\r\n; added by dver\r\nDFLAGS=-I%@P%/" ~ relSrcPath ~ "/phobos -L-L%@P%/../lib\r\n";
					suffix = suffix.replace("%@P%", binPath); // %@P% support in dmd.conf was added cca D 0.115
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
				if (compiler == Compiler.dmd && "/etc/dmd.conf".exists && confPath.exists && !wine)
					command = [
						"bwrap",
					] ~ (
						dirEntries("/", SpanMode.shallow)
						.filter!(de => de.isDir)
						.map!(de => de.isSymlink
							? ["--symlink", de.readLink, de.name]
							: ["--dev-bind", de.name, de.name]
						).join
					) ~ [
						"--bind", binPath ~ "/dmd.conf", "/etc/dmd.conf",
						// 1.022 patch (doesn't look in its own bin directory for dmd.conf; paths are relative to the found dmd.conf):
						"--dir", "/src",
						"--bind", dir.buildPath(srcDir), "/src",
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
