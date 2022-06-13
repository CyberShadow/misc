/**
   Arrange files in the current directory into subdirectories
   according to their modification date.
*/

import std.algorithm;
import std.array;
import std.datetime;
import std.file;
import std.getopt;
import std.path;
import std.regex;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.aa;
import ae.utils.regex;
import ae.utils.time;

void main(string[] args)
{
	bool sortDirs;
	getopt(args,
		"d|dirs", &sortDirs,
	);

	DirEntry[] candidates;
	version (Windows)
	{
		string[] masks = args[1..$];
		if (!masks.length)
			masks = ["*"];
		foreach (mask; masks)
			candidates ~= dirEntries("", mask, SpanMode.shallow).array;
	}
	else
	{
		candidates = args[1..$].map!(arg => DirEntry(arg)).array;
		if (!candidates.length)
			candidates = dirEntries("", SpanMode.shallow).array;
	}

	string[] targets;
	int[string] extCount, dateCount;

	foreach (DirEntry de; candidates)
	{
		if (!sortDirs && de.isDir)
			continue;
		if (de.isDir && de.baseName.match(re!`^20\d\d-\d\d-\d\d`))
			continue;
		targets ~= de;
		extCount[toLower(de.name.extension)]++;
		dateCount[de.timeLastModified.formatTime!"Ymd"]++;
	}

	string[] extCountStr;
	foreach (ext, count; extCount)
		extCountStr ~= format("%d %s", count, ext);
	writefln("Sort %d files (%-(%s, %)) to %d per-date directories? (Enter to continue, ^C to abort)",
		targets.length,
		extCount.byPair.map!(p => "%d %s".format(p.value, p.key.length ? p.key : "extensionless")),
		dateCount.length,
	);
	readln();

	foreach (target; targets)
	{
		string fn = buildPath(target.timeLastModified.formatTime!"Y-m-d", target.baseName);
		ensurePathExists(fn);
		rename(target, fn);
	}
}
