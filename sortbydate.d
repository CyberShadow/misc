#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Arrange files in the current directory into subdirectories
   according to their modification date.
*/

import std.algorithm;
import std.array;
import std.datetime;
import std.exception;
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
	Switch!("Rename date directories instead of attempting to merge them", 'r') noMerge = false,
	Switch!("Skip interactive confirmation", 'y') noConfirm = false,
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

	string[2][] items;
	int[string] extCount, dateCount;

	foreach (DirEntry de; candidates)
	{
		if (!sortDirs && de.isDir)
			continue;
		if (de.isDir && de.baseName.match(re!`^20\d\d-\d\d-\d\d`) && !target)
			continue;
		string sourceItem = de.name;
		auto dateDir = sourceItem.timeLastModified.formatTime!"Y-m-d";
		string suffix = "";
		@property targetItem() { return buildPath(target, dateDir ~ suffix, sourceItem.baseName); }
		if (noMerge)
			while (targetItem.dirName.exists)
				suffix = suffix.length ? [cast(char)(suffix[0] + 1)].assumeUnique : "b";

		items ~= [sourceItem, targetItem];
		extCount[toLower(de.extension)]++;
		dateCount[de.timeLastModified.formatTime!"Ymd"]++;
	}

	if (!noConfirm)
	{
		string[] extCountStr;
		foreach (ext, count; extCount)
			extCountStr ~= format("%d %s", count, ext);
		writefln("Sort %d files (%-(%s, %)) to %d per-date directories? (Enter to continue, ^C to abort)",
			items.length,
			extCount.byPair.map!(p => "%d %s".format(p.value, p.key.length ? p.key : "extensionless")),
			dateCount.length,
		);
		readln();
	}

	foreach (item; items)
	{
		auto targetItem = item[1];
		auto sourceItem = item[0];
		enforce(!targetItem.exists, "Refusing to overwrite '%s' with '%s'.".format(targetItem, sourceItem));
	}

	foreach (item; items)
	{
		auto targetItem = item[1];
		auto sourceItem = item[0];
		ensurePathExists(targetItem);
		rename(sourceItem, targetItem);
	}
}

mixin main!(funopt!program);
