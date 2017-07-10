import core.time;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.datetime.date;
import std.datetime.systime;
import std.exception;
import std.file;
import std.getopt;
import std.parallelism;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.utils.meta;
import ae.utils.time.format;

enum dmdDir = "/home/vladimir/data/software/dmd";
enum canBisectAfter = Date(2011, 07, 01);

void main(string[] args)
{
	string minVer = "1.0";
	bool doBisect, singleThreadedSwitch;
	string[] without = ["rdmd"];
	getopt(args,
		"b", &doBisect,
		"without", &without,
		"s", &singleThreadedSwitch,
		config.stopOnFirstNonOption,
	);

	static bool compareVersion(string a, string b)
	{
		static string normalizeVersion(string v)
		{
			if (v.length == 5 || v[5] != '.')
				v = v[0..5] ~ ".0" ~ v[5..$];
			if (!v.canFind("-b"))
				v ~= "-b0";
			return v;
		}
		return normalizeVersion(a) < normalizeVersion(b);
	}

	auto versions = dmdDir
		.dirEntries("dmd.2.???*", SpanMode.shallow)
		.filter!(de => de.isDir)
		.filter!(de => !de.name.endsWith(".windows"))
		.map!(de => de.baseName[4..$].chomp(".linux"))
		.filter!(ver => ver >= minVer)
		.array
		.sort!compareVersion
		.release;

	versions = versions
		.filter!(ver => !doBisect || (ver.length == 5 || ver.endsWith(".0")) || ver[0..5] == versions[$-1][0..5]) // Stable branches interfere with bisection
		.array
		.sort!compareVersion
		.uniq
		.array;

	bool multiThreaded = !singleThreadedSwitch;
	if (args.canFind("-run") || args[1] == "rdmd" || args[1].endsWith("sh"))
		multiThreaded = false;

	alias ExecResult = typeof(execute(args));
	ExecResult[string] results;

	void processVersion(string ver)
	{
		auto result = execute(["dver", ver] ~ args[1..$]);

		result.output = result.output
			.replace(dmdDir ~ `/dmd.` ~ ver, "/path/to/dmd")
			;

		synchronized
		{
			results[ver] = result;
			writef!"%d/%d\r"(results.length, versions.length); stdout.flush();
		}
	}

	if (multiThreaded)
		foreach (ver; versions.parallel) processVersion(ver);
	else
		foreach (ver; versions         ) processVersion(ver);

	enum col(int c) = c==0 ? "\033[0m" : c==7 ? "\033[0;1m" : format!"\033[1;%dm"(30 + c);

	SysTime verDate(string ver)
	{
		auto result = execute(["dver", ver, "which", "dmd"]);
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
		assert((r1.status == 0) != (r2.status == 0), "TODO");

		bool reverse = r1.status != 0;

		auto iniFn = format!"bisect-%s-%s.ini"(v1, v2);
		string[] ini;
		ini ~= format!"%s = %s @ %s"(reverse ? "bad " : "good", branch, (verDate(v1)-40.days).formatTime!"Y-m-d H:i:s");
		ini ~= format!"%s = %s @ %s"(reverse ? "good" : "bad ", branch, (verDate(v2)+30.days).formatTime!"Y-m-d H:i:s");
		ini ~= format!"reverse = %s"(reverse);
		ini ~= format!"tester = %s"(args[1..$].I!toBisectIniCmd);
		foreach (c; without)
			ini ~= format!"build.components.enable.%s = false"(c);
		ini.join("\n").toFile(iniFn);

		auto p = pipe();
		auto pid = spawnProcess(["bisect-online", iniFn], stdin, p.writeEnd, p.writeEnd);
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
		lines = lines.filter!((ref line) => line.skipOver("    ") && line.length).array;
		enforce(lines.length >= 3, "Can't find URL in bisect output");

		if (branch == "master")
		{
			if (lines[2].startsWith("Merge remote-tracking branch 'upstream/stable'")
			 || lines[2].startsWith("Merge branch 'merge_stable_convert' into merge_stable"))
				return bisect(v1, v2, "stable");
		}

		return col!6 ~ lines[1] ~ col!0 ~ " - " ~ col!3 ~ lines[2] ~ col!0;
	}

	string[] bisectResults;

	size_t[] changes;

	foreach (index; 1..versions.length)
		if (results[versions[index-1]] != results[versions[index]])
		{
			changes ~= index;

			if (doBisect)
			{
				if ((results[versions[index-1]].status==0) != (results[versions[index]].status==0) && verDate(versions[index-1]) > SysTime(canBisectAfter))
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
					writefln!"  %sBroken %s by: %s%s"(col!1, col!7, bisectResults[idx], col!0);
				else
				if (results[versions[changes[idx]-1]].status != 0 && results[versions[changes[idx]]].status == 0)
					writefln!"  %sFixed  %s by: %s%s"(col!2, col!7, bisectResults[idx], col!0);
				else
					writefln!"  %sChanged by: %s%s"(col!7, bisectResults[idx], col!0);
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
