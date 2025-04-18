#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   D regression tester.

   Runs a command against all installed D versions, and summarizes the
   result. With -b, bisects success/failure status changes.
*/

module dreg;

import core.time;

import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.datetime.date;
import std.datetime.systime;
import std.exception;
import std.file;
import std.net.curl;
import std.parallelism;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta;
import ae.utils.regex;
import ae.utils.text;
import ae.utils.time.format;

enum canBisectAfter = Date(2011, 07, 01);

@(`Runs a command against all DMD versions.

Example: dreg -d dmd -o- test.d`)
void program(
	Parameter!(string, "Program to run (e.g. `dmd`)") program,
	Parameter!(string[], "Arguments to program to run (e.g. `-o- test.d`)") programArgs = null,
	Switch!("Bisect the cause of changes in success/failure", 'b', "bisect") doBisect = false,
	Switch!("Bisect all changes in exit status", 0, "status") doBisectStatus = false,
	Switch!("Bisect all changes in output", 0, "output") doBisectOutput = false,
	Switch!("Instead of downloading releases, build D with Digger", 'D', "digger") useDigger = false,
	Option!(string[], "When building D with Digger, build without these components", "COMPONENT") without = null,
	Switch!("Download all missing D versions", 'd', "download") doDownload = false,
	Switch!("Force single-threaded execution", 's', "single-threaded") singleThreadedSwitch = false,
	Switch!("Target 32-bit", 0, "32") use32Bit = false,
	Option!(string, "Minimum version", "VERSION", 0, "min") minVer = "1.0",
	Option!(string, "Maximum version", "VERSION", 0, "max") maxVer = null,
) {
	auto dverPath = thisExePath.dirName.buildPath("dver");
	version (Windows) dverPath ~= ".exe";
	string[] dverArgs = [dverPath];
	if (use32Bit)
		dverArgs ~= "--32";
	auto args = ["dreg", program] ~ programArgs;

	auto downloadDir = environment.get("DMD_DOWNLOAD_DIR", null)
		.enforce("Please set the environment variable DMD_DOWNLOAD_DIR to " ~
			"the location where DMD versions should be downloaded and unpacked."
		);
	auto digger = environment.get("DIGGER", "digger");

	static bool compareVersion(string a, string b)
	{
		static string normalizeVersion(string v)
		{
			if (v.length == 4 && v[1] == '.')
				v = v[0..2] ~ '0' ~ v[2..$];
			if (v.length == 5 || v[5] != '.')
				v = v[0..5] ~ ".0" ~ v[5..$];
			if (!v.canFind("-b"))
				v ~= "-b0";
			return v;
		}
		return normalizeVersion(a) < normalizeVersion(b);
	}

	write("Enumerating...\r"); stdout.flush();
	string[] versions;
	if (doDownload)
	{
		versions =
			get("http://ftp.digitalmars.com/")
			.assumeUnique
			.splitLines
			.filter!(line => line.startsWith(`<li><a href="dmd.`))
			.map!(line => line.split('"')[1])
			.map!((fileName) {
				if (only("~beta.", "~rc.", "-beta.", "-rc.", "-b", "-rc1.", "-rc2.").any!(s => fileName.canFind(s)))
					return null;
				if (fileName.among(`dmd..beta.3.zip`, `dmd.120.2.zip`, `dmd.zip`))
					return null; // odd-balls
				if (auto m = fileName.matchFirst(re!`^dmd\.([0-9]*)\.zip$`))
					return "0." ~ m[1];
				if (auto m = fileName.matchFirst(re!`^dmd\.([0-9]\.[0-9][0-9][0-9]\.[0-9])\.`))
					return m[1];
				if (auto m = fileName.matchFirst(re!`^dmd\.([0-9]\.[0-9][0-9][0-9]?)\.[^0-9]`))
					return m[1];
				stderr.writeln("Failed to extract DMD version: ", fileName);
				return null;
			})
			.filter!((ver) {
				if (ver is null)
					return false; // Did not extract a version from the filename
				if (ver.among("2.063.2", "2.064.2", "2.065"))
					return false; // Odd-ball "versions" during transition to point-releases
				return true;
			})
			.array
			.sort
			.uniq
			.array;
		dverArgs ~= "--download";
	}
	else
	{
		versions = downloadDir
			.dirEntries("dmd.*", SpanMode.shallow)
			.filter!(de => de.isDir)
			.filter!(de => !de.name.endsWith(".windows"))
			.filter!(de => !de.name.endsWith(".nixified"))
			.map!(de => de.baseName[4..$].chomp(".linux"))
			.filter!(ver =>          ver >= minVer       )
			.filter!(ver => maxVer ? ver <= maxVer : true)
			.array
			.sort!compareVersion
			.release;
		enforce(versions.length, "No DMD versions found. Maybe run with -d first?");
	}

	versions = versions
		.filter!(ver => !doBisect || ver.startsWith("2.")) // When bisecting, assume we want only the 2.x branch
		.filter!(ver => !doBisect || (ver.length == 5 || ver.endsWith(".0")) || ver[0..5] == versions[$-1][0..5]) // Stable branches interfere with bisection
		.array
		.sort!compareVersion
		.uniq
		.array;

	bool multiThreaded = !singleThreadedSwitch;
	if (args.canFind("-run") || args[1] == "rdmd" || args[1].endsWith("sh") || useDigger)
		multiThreaded = false;

	if (without is null && args[1] != "rdmd")
		without ~= "rdmd";

	alias ExecResult = typeof(execute(args));
	ExecResult[string] results;

	string[] dCommand(string ver)
	{
		if (useDigger)
			return [digger, "--quiet", "run", ver, "--"];
		else
			return dverArgs ~ [ver];
	}

	void processVersion(string ver)
	{
		auto result = execute(dCommand(ver) ~ args[1..$]);

		result.output = result.output
			.replace(downloadDir.buildPath(`dmd.` ~ ver), "/path/to/dmd")
			.replaceAll(re!(`^(/path/to/dmd[^():]*?)\([0-9]+\): `, "m"), `$1(#): `)
			.replaceAll(re!(`^(\?\?:\? .* \[0x)[0-9a-f]*\]$`, "m"), `$1...]`)
			;

		synchronized
		{
			results[ver] = result;
			writef!"%d/%d          \r"(results.length, versions.length); stdout.flush();
		}
	}

	if (multiThreaded)
		foreach (ver; versions.parallel) processVersion(ver);
	else
		foreach (ver; versions         ) processVersion(ver);

	enum col(int c) = c==0 ? "\033[0m" : c==7 ? "\033[0;1m" : format!"\033[1;%dm"(30 + c);

	SysTime verDate(string ver)
	{
		auto result = execute(dverArgs ~ [ver, "which", "dmd"]);
		enforce(result.status == 0, "Failed to find the dmd executable path to " ~ ver);
		auto exe = result.output.strip();
		return exe.timeLastModified();
	}

	static string toBisectIniCmd(string[] args)
	{
		import std.ascii : isAlphaNum;
		if (args[0].endsWith("sh") && !args[0].endsWith(".sh") && args[1] == "-c" && args.length == 3)
			return args[2];
		else
		if (args.all!(arg => arg.all!(c => c.isAlphaNum || "-._/".canFind(c))))
			return args.join(" ");
		else
			return escapeShellCommand(args);
	}

	string bisect(string v1, string v2, string branch = "master")
	{
		stderr.writefln!"=== Bisecting %s to %s (%s) ==="(v1, v2, branch);
		auto r1 = results[v1];
		auto r2 = results[v2];

		auto iniFn = format!"bisect-%s-%s.ini"(v1, v2);
		string[] ini;
		bool reverse;
		if (doBisectOutput)
		{
			auto lines1 = r1.output.splitAsciiLines;
			auto lines2 = r2.output.splitAsciiLines;

			string goodLine;

			foreach (l1; lines1)
			{
				goodLine = l1;
				foreach (l2; lines2)
					if (l1 == l2)
					{
						goodLine = null;
						break;
					}
				if (goodLine)
					break;
			}

			if (!goodLine)
			{
				reverse = true;
				foreach (l2; lines2)
				{
					goodLine = l2;
					foreach (l1; lines1)
						if (l1 == l2)
						{
							goodLine = null;
							break;
						}
					if (goodLine)
						break;
				}
			}

			enforce(goodLine, "Can't find unique line to bisect on");

			ini ~= format!"tester = %s 2>&1 | %s"(args[1..$].I!toBisectIniCmd, escapeShellCommand(["grep", "-xF", goodLine]));
		}
		else
		if (doBisectStatus)
		{
			assert(r1.status != r2.status);
			ini ~= format!"tester = %s ; status=$? ; if [ $status -eq %s ] ; then exit 0 ; elif [ $status -eq %s ] ; then exit 1 ; else exit 125 ; fi"(args[1..$].I!toBisectIniCmd, r1.status, r2.status);
		}
		else
		{
			assert((r1.status == 0) != (r2.status == 0));
			reverse = r1.status != 0;
			ini ~= format!"tester = %s"(args[1..$].I!toBisectIniCmd);
		}
		ini ~= format!"%s = %s @ %s"(reverse ? "bad " : "good", branch, (verDate(v1)-40.days).formatTime!"Y-m-d H:i:s");
		ini ~= format!"%s = %s @ %s"(reverse ? "good" : "bad ", branch, (verDate(v2)+30.days).formatTime!"Y-m-d H:i:s");
		ini ~= format!"reverse = %s"(reverse);
		foreach (c; without)
			ini ~= format!"build.components.enable.%s = false"(c);
		ini.join("\n").toFile(iniFn);

		auto p = pipe();
		auto pid = spawnProcess([digger, "bisect", iniFn], stdin, p.writeEnd, p.writeEnd);
		string[] lines;
		while (!p.readEnd.eof)
		{
			auto line = p.readEnd.readln();
			lines ~= line.chomp();
			stderr.write(line);
		}

		enforce(pid.wait() == 0, "Bisection failed");

		lines = lines.find!(line => line.endsWith(format!" is the first %s commit"(reverse ? "good" : "bad")));
		enforce(lines.length, "Can't find bisection result");
		auto commitMessage = lines.filter!((ref line) => line.skipOver("    ") && line.length).array;

		if (branch == "master")
		{
			if (commitMessage.any!(line =>
					line.startsWith("Merge remote-tracking branch 'upstream/stable'") ||
					line.startsWith("Merge branch 'merge_stable_convert' into merge_stable") ||
					line.startsWith("merge stable")
				))
				return bisect(v1, v2, "stable");
		}

		if (commitMessage.length >= 3 && commitMessage[1].startsWith("https://github.com/"))
			return col!6 ~ commitMessage[1] ~ col!0 ~ " - " ~ col!3 ~ commitMessage[2] ~ col!0;
		else
		{
			// D-dot-git failed to extract a link to the pull request; just link to the repo commit
			lines = lines.map!(line => line.replaceAll(re!"\033\\[.*?m", "")).array; // Strip ANSI codes
			auto repo = lines.filter!((ref line) => line.skipOver("+++ b/")).front;
			auto commit = lines.filter!((ref line) => line.skipOver("+Subproject commit ")).front;
			return col!6 ~ "https://github.com/dlang/" ~ repo ~ "/commit/" ~ commit ~ col!0 ~ " - " ~ col!3 ~ commitMessage[0].findSplit(": ")[2] ~ col!0;
		}
		// else
		// 	throw new Exception("Can't find URL in bisect output");
	}

	string[] bisectResults;

	size_t[] changes;

	foreach (index; 1..versions.length)
		if (results[versions[index-1]] != results[versions[index]])
		{
			changes ~= index;

			if (doBisect)
			{
				bool eqv;
				if (doBisectOutput)
					eqv = results[versions[index-1]] == results[versions[index]];
				else
				if (doBisectStatus)
					eqv = results[versions[index-1]].status == results[versions[index]].status;
				else
					eqv = (results[versions[index-1]].status==0) == (results[versions[index]].status==0);
				if (!eqv && (verDate(versions[index-1]) > SysTime(canBisectAfter)).ifThrown(false))
					try
						bisectResults ~= bisect(versions[index-1], versions[index]);
					catch (Exception e)
						bisectResults ~= format!"%s(%s)%s"(col!1, e.msg, col!0);
				else
					bisectResults ~= null;
			}
		}

	string resultStr(ref ExecResult r)
	{
		string s;
		switch (r.status)
		{
			case   0: s = "Success" ; break;
			case   1: s = "Failure" ; break;
			case 124: s = "Timeout" ; break;
			case -11: s = "Segfault"; break;
			default:  s = format!"Status %d"(r.status);
		}
		s = (r.status ? col!1 : col!2) ~ s ~ col!7;

		if (r.output.length)
		{
			if (r.output.strip().canFind('\n'))
				s ~= " with output:\n-----\n" ~ col!0 ~ r.output.strip() ~ col!7 ~ "\n-----\n";
			else
				s ~= " with output: " ~ col!0 ~ r.output.strip() ~ col!7;
		}
		else
			s ~= " and no output";

		return s;
	}

	string verStr(string ver)
	{
		return format!"%s%-7s%s"(col!5, ver, col!7);
	}

	if (!changes.length)
		writefln!"%sAll versions: %s%s"(col!7, resultStr(results[versions[0]]), col!0);
	else
	{
		writefln!"%sUp to      %s: %s%s"(col!7, verStr(versions[changes[0]-1]), resultStr(results[versions[changes[0]-1]]), col!0);
		foreach (idx; 0..changes.length)
		{
			if (doBisect && bisectResults[idx])
			{
				if (results[versions[changes[idx]-1]].status == 0 && results[versions[changes[idx]]].status != 0)
					writefln!"> %sBroken %s by: %s%s"(col!1, col!7, bisectResults[idx], col!0);
				else
				if (results[versions[changes[idx]-1]].status != 0 && results[versions[changes[idx]]].status == 0)
					writefln!"> %sFixed  %s by: %s%s"(col!2, col!7, bisectResults[idx], col!0);
				else
					writefln!"> %sChanged by: %s%s"(col!7, bisectResults[idx], col!0);
			}
			if (idx+1 < changes.length)
			{
				if (changes[idx] == changes[idx+1]-1)
					writefln!"           %s: %s%s"(verStr(versions[changes[idx]]), resultStr(results[versions[changes[idx]]]), col!0);
				else
					writefln!"%s to %s: %s%s"(verStr(versions[changes[idx]]), verStr(versions[changes[idx+1]-1]), resultStr(results[versions[changes[idx]]]), col!0);
			}
			else
				writefln!"%sSince      %s: %s%s"(col!7, verStr(versions[changes[$-1]]), resultStr(results[versions[changes[$-1]]]), col!0);
		}
	}
}

enum FunOptConfig config = {
	import std.getopt : config;
	FunOptConfig c;
	c.getoptConfig ~= config.stopOnFirstNonOption;
	c.getoptConfig ~= config.caseSensitive;
	return c;
}();

mixin main!(funopt!(program, config));
