/**
   Prepare a commit message template based on which files are
   modified. To be used with the git-prepare-commit-msg hook.
*/

module git_status_to_commit_msg;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.utils.array;

void main(string[] args)
{
	string prefix = args.length > 1
		? args[1]
		: getcwd.buildNormalizedPath(environment.get("GIT_DIR", ".git")).dirName().baseName();

	string[] lines;
	while (!stdin.eof)
		lines ~= readln().chomp().idup;

	auto files = lines.filter!(line => line.length && line[0].isOneOf("AM")).map!(line => line[3..$]).array;
	string targetExt;
	foreach (ext; [".d", ".el", ".bash", ".sh"])
		if (files.any!(file => file.endsWith(ext)))
		{
			targetExt = ext;
			break;
		}
	auto extensions = files.map!extension.array.sort.uniq.array;
	if (extensions.length == 1)
		targetExt = extensions[0];

	string packStaged, packWD;
	foreach (line; lines)
	{
		if (line.length > 3)
		{
			void handleLine(string line, ref string pack)
			{
				if (targetExt.length && !line.endsWith(targetExt))
					return;
				auto mod = line[0 .. $ - targetExt.length];
				char delim = '/';
				if (targetExt == ".d")
				{
					delim = '.';
					mod = mod.replace("/", [delim]);
					if (!mod.skipOver("src" ~ delim))
						mod = prefix ~ delim ~ mod;
				}
				if (pack)
					pack = commonPrefix(mod, pack).stripRight(delim);
				else
					pack = mod;
			}
			handleLine(line[3..$], line[0].isOneOf("AM") ? packStaged : packWD);
		}
	}
	if (packStaged.length)
		stdout.write(packStaged, ": ");
	else
	if (packWD.length)
		stdout.write(packWD, ": ");
}
