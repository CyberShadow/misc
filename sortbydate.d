/**
   Arrange files in the current directory into subdirectories
   according to their modification date.
*/

import std.algorithm;
import std.array;
import std.datetime;
import std.file;
import std.path;
import std.regex;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.regex;
import ae.utils.time;

void program(
	Switch!("Sort directories too, not just files", 'd') dirs = false,
	Option!(string, "Create dated directories here (instead of the current directory)", "DIR", 't') target = null,
	string[] paths = null,
)
{
	bool sortDirs = dirs.value;
	DirEntry[] candidates;
	version (Windows)
	{
		string[] masks = paths;
		if (!masks.length)
			masks = ["*"];
		foreach (mask; masks)
			candidates ~= dirEntries("", mask, SpanMode.shallow).array;
	}
	else
	{
		candidates = paths.map!(arg => DirEntry(arg)).array;
		if (!candidates.length)
			candidates = dirEntries("", SpanMode.shallow).array;
	}

	string[] items;
	int[string] extCount, dateCount;

	foreach (DirEntry de; candidates)
	{
		if (!sortDirs && de.isDir)
			continue;
		if (de.isDir && de.baseName.match(re!`^20\d\d-\d\d-\d\d`))
			continue;
		items ~= de;
		extCount[toLower(de.name.extension)]++;
		dateCount[de.timeLastModified.formatTime!"Ymd"]++;
	}

	string[] extCountStr;
	foreach (ext, count; extCount)
		extCountStr ~= format("%d %s", count, ext);
	writefln("Sort %d files (%-(%s, %)) to %d per-date directories? (Enter to continue, ^C to abort)",
		items.length,
		extCount.byPair.map!(p => "%d %s".format(p.value, p.key.length ? p.key : "extensionless")),
		dateCount.length,
	);
	readln();

	foreach (item; items)
	{
		string fn = buildPath(target, item.timeLastModified.formatTime!"Y-m-d", item.baseName);
		ensurePathExists(fn);
		rename(item, fn);
	}
}

mixin main!(funopt!program);
