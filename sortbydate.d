import std.algorithm;
import std.datetime;
import std.file;
import std.getopt;
import std.path;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.aa;
import ae.utils.time;

void main(string[] args)
{
	bool sortDirs;
	getopt(args,
		"d|dirs", &sortDirs,
	);

	string[] targets;
	int[string] extCount, dateCount;
	string[] masks = args[1..$];
	if (!masks.length)
		masks = ["*"];
	foreach (mask; masks)
		foreach (DirEntry de; dirEntries("", mask, SpanMode.shallow))
			if (sortDirs || de.isFile)
				targets ~= de,
				extCount[toLower(de.name.extension)]++,
				dateCount[de.timeLastModified.format("Ymd")]++;

	string[] extCountStr;
	foreach (ext, count; extCount)
		extCountStr ~= format("%d %s", count, ext);
	writefln("Sort %d files (%-(%s, %)) to %d per-date directories? (Enter to continue, ^C to abort)",
		targets.length,
		extCount.pairs.map!(p => "%d %s".format(p.value, p.key)),
		dateCount.length,
	);
	readln();

	foreach (target; targets)
	{
		string fn = buildPath(target.timeLastModified.format("Y-m-d"), target.baseName);
		ensurePathExists(fn);
		rename(target, fn);
	}
}
