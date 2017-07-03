import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.file;
import std.getopt;
import std.parallelism;
import std.path;
import std.process;
import std.stdio;
import std.string;

enum dmdDir = "/home/vladimir/data/software/dmd";

void main(string[] args)
{
	string minVer = "1.0";
	getopt(args,
		config.stopOnFirstNonOption,
	);

	auto versions = dmdDir
		.dirEntries("dmd.2.???*", SpanMode.shallow)
		.filter!(de => de.isDir)
		.filter!(de => !de.name.endsWith(".windows"))
		.map!(de => de.baseName[4..$].chomp(".linux"))
		.filter!(ver => ver >= minVer)
		.filter!(ver => !ver.canFind("-b")) // TODO betas?
		.array
		.sort()
		.uniq
		.array;

	bool multiThreaded = true;
	if (args.canFind("-run") || args[1] == "rdmd")
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

	size_t[] changes;
	foreach (index; 1..versions.length)
		if (results[versions[index-1]] != results[versions[index]])
			changes ~= index;

	static string col(int col) { return col==0 ? "\033[0m" : col==7 ? "\033[0;1m" : format!"\033[1;%dm"(30 + col); }

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
		s = col(r.status ? 1 : 2) ~ s ~ col(7);

		if (r.output.length)
		{
			if (r.output.strip().canFind('\n'))
				s ~= " with output:\n-----\n" ~ col(0) ~ r.output.strip() ~ col(7) ~ "\n-----\n";
			else
				s ~= " with output: " ~ col(0) ~ r.output.strip() ~ col(7);
		}
		else
			s ~= " and no output";

		return s;
	}

	string verStr(string ver)
	{
		return format!"%s%-7s%s"(col(5), ver, col(7));
	}

	if (!changes.length)
		writeln("All versions: ", resultStr(results[versions[0]]));
	else
	{
		writefln!"Up to      %s: %s"(verStr(versions[changes[0]-1]), resultStr(results[versions[changes[0]-1]]));
		foreach (idx; 0..changes.length-1)
			if (changes[idx] == changes[idx+1]-1)
				writefln!"           %s: %s"(verStr(versions[changes[idx]]), resultStr(results[versions[changes[idx]]]));
			else
				writefln!"%s to %s: %s"(verStr(versions[changes[idx]]), verStr(versions[changes[idx+1]-1]), resultStr(results[versions[changes[idx]]]));
		writefln!"Since      %s: %s"(verStr(versions[changes[$-1]]), resultStr(results[versions[changes[$-1]]]));
	}
}
