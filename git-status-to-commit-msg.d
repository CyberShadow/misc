/**
   Prepare a commit message template based on which files are
   modified. To be used with the git-prepare-commit-msg hook.
*/

module git_status_to_commit_msg;

import std.algorithm;
import std.array;
import std.exception;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.stdio : stdin, stdout, stderr;
import std.string;

import ae.utils.array;
import ae.utils.meta;
import ae.utils.sini;

struct Config
{
	string[] maskPriority;

	struct Mask
	{
		string mask;
		bool stripExt = true;
		char delim = 0;
		string[] stripPrefixes;
		bool addPrefix;
		string prefix;
	}
	OrderedMap!(string, Mask) masks;
}

enum defaultConfig = q"EOF
maskPriority = ["*.d", "*.el", "*.{bash,sh}"]

[masks.src-d]
mask = {src/,*/src/}*.d
delim = .
stripPrefixes = ["src."]

[masks.d]
mask = *.d
delim = .
addPrefix = true

[masks.all]
mask = *
stripExt = false
EOF";

void main(string[] args)
{
	string gitDir = environment.get("GIT_DIR");
	string workTree;
	if (gitDir)
		workTree = gitDir.buildPath("..");
	else
	{
		workTree = getcwd;
		while (true)
		{
			gitDir = workTree.buildPath(".git");
			if (gitDir.exists)
				break;
			auto parentDir = workTree.dirName;
			enforce(parentDir != workTree, "Can't find .git directory");
			workTree = parentDir;
		}
		if (gitDir.isFile)
			gitDir = gitDir.dirName.buildPath(gitDir.readText.strip.I!(gitDir => progn(enforce(gitDir.skipOver("gitdir: ", ".git file does not start with .gitdir")), gitDir)));
	}

	Config config;
	auto configFiles = [
		gitDir.buildPath("git-status-to-commit-msg.ini"),
		workTree.buildPath("git-status-to-commit-msg.ini"),
	].filter!exists;
	if (configFiles.empty)
		config = parseIni!Config(defaultConfig.splitLines);
	else
		config = loadIni!Config(configFiles.front);

	bool verbose;
	getopt(args,
		"v|verbose", &verbose,
	);
	string defaultPrefix = args.length > 1
		? args[1]
		: workTree.absolutePath.baseName();

	string[] lines;
	while (!stdin.eof)
		lines ~= stdin.readln().chomp().idup;

	auto files = lines.filter!(line => line.length && !line[0].isOneOf(" ?")).map!(line => line[3..$]).array;
	string targetMask;
	foreach (mask; config.maskPriority)
		if (files.any!(file => file.globMatch(mask)))
		{
			if (verbose) stderr.writefln("Detected priority mask: %s (matched file %s)", mask, files.find!(file => file.globMatch(mask)).front);
			targetMask = mask;
			break;
		}
	// auto extensions = files.map!extension.array.sort.uniq.array;
	// if (extensions.length == 1)
	// 	targetExt = extensions[0];

	string packStaged, packWD;
	foreach (line; lines)
	{
		if (line.length > 3)
		{
			void handleLine(string line, ref string pack)
			{
				if (targetMask.length && !line.globMatch(targetMask))
					return;
				Config.Mask mask;
				foreach (name, maskConfig; config.masks)
					if (line.globMatch(maskConfig.mask))
					{
						mask = maskConfig;
						break;
					}
				string mod = line;
				if (mask.stripExt)
					mod = mod.stripExtension;
				char delim = '/';
				if (mask.delim)
				{
					delim = mask.delim;
					mod = mod.replace("/", [delim]);
				}
				foreach (prefix; mask.stripPrefixes)
					if (mod.skipOver(prefix))
						break;
				if (mask.addPrefix)
					mod = (mask.prefix ? mask.prefix : defaultPrefix) ~ delim ~ mod;
				if (pack)
					pack = commonPrefix(mod, pack).stripRight(delim);
				else
					pack = mod;
			}
			handleLine(line[3..$], !line[0].isOneOf(" ?") ? packStaged : packWD);
		}
	}
	auto pack = packStaged ? packStaged : packWD;
	if (pack.length)
		stdout.write(pack, ": ");
}
