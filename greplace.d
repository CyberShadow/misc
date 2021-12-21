/**
   Replace a raw string in the given files and file names.

   By default, ensures that the operation is undoable, i.e. aborts if
   the new string is already found in any of the files.
*/

module greplace;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.getopt;
import std.path;
import std.range;
import std.stdio;
import std.string;

import ae.utils.main;
import ae.utils.funopt;

void greplace(
	Switch!("Perform replacement even if it is not reversible", 'f') force,
	Switch!("Do not actually make any changes", 'n') dryRun,
	Switch!("Search and replace in UTF-16") wide,
	Switch!("Only search and replace in file names and paths") noContent,
	Switch!("Recurse in symlinked directories") followSymlinks,
	Switch!("Swap FROM-STR and TO-STR", 'r') reverse,
	Parameter!(string, "String to search") fromStr,
	Parameter!(string, "String to replace with") toStr,
	Parameter!(string[], "Paths (files or directories) to search in (default is current directory)") targets = null,
)
{
	if (!targets.length)
		targets = [""];

	if (reverse)
		swap(fromStr.value, toStr.value);

	ubyte[] from, to, fromw, tow;
	from = cast(ubyte[])fromStr;
	to   = cast(ubyte[])toStr;

	if (wide)
	{
		fromw = cast(ubyte[])std.conv.to!wstring(fromStr);
		tow   = cast(ubyte[])std.conv.to!wstring(toStr);
	}

	auto targetFiles = targets.map!(target =>
		target.empty || target.isDir
		? dirEntries(target, SpanMode.breadth, followSymlinks).array
		: [DirEntry(target)]).array;

	if (!force)
	{
		foreach (targetIndex, target; targets)
			foreach (ref file; targetFiles[targetIndex])
			{
				ubyte[] s;
				if (file.isSymlink())
					s = cast(ubyte[])readLink(file.name);
				else
				if (file.isFile() && !noContent)
					s = cast(ubyte[])std.file.read(file.name);

				if (s)
				{
					if (s.replace(from, to).replace(to, from) != s)
						throw new Exception("File " ~ file.name ~ " already contains " ~ toStr);
					if (wide && s.replace(fromw, tow).replace(tow, fromw) != s)
						throw new Exception("File " ~ file.name ~ " already contains " ~ toStr ~ " (in UTF-16)");
				}

				if (file.name.replace(fromStr[], toStr[]).replace(toStr[], fromStr[]) != file.name)
					throw new Exception("File name " ~ file.name ~ " already contains " ~ toStr);
			}
	}

	foreach (targetIndex, target; targets)
		foreach (ref file; targetFiles[targetIndex])
		{
			// Apply renames of parent directories
			string fileName;
			foreach (segment; file.name.pathSplitter)
			{
				if (fileName.length > target.length)
					fileName = fileName.replace(from, to);
				fileName = fileName.buildPath(segment);
			}

			ubyte[] s;
			if (file.isSymlink())
				s = cast(ubyte[])readLink(fileName);
			else
			if (file.isFile() && !noContent)
				s = cast(ubyte[])std.file.read(fileName);

			if (s)
			{
				bool modified = false;
				if (s.countUntil(from)>=0)
				{
					s = s.replace(from, to);
					modified = true;
				}
				if (wide && s.countUntil(fromw)>=0)
				{
					s = s.replace(fromw, tow);
					modified = true;
				}

				if (modified)
				{
					writeln(file.name);

					if (!dryRun)
					{
						if (file.isSymlink())
						{
							remove(fileName);
							symlink(cast(string)s, fileName);
						}
						else
						if (file.isFile())
							std.file.write(fileName, s);
						else
							assert(false);
					}
				}
			}

			if (fileName.indexOf(fromStr)>=0)
			{
				string newName = fileName.replace(fromStr.value, toStr.value);
				writeln(fileName, " -> ", newName);

				if (!dryRun)
				{
					if (!exists(dirName(newName)))
						mkdirRecurse(dirName(newName));
					std.file.rename(fileName, newName);

					// TODO: empty folders

					auto segments = array(pathSplitter(fileName))[0..$-1];
					foreach_reverse (i; 0..segments.length)
					{
						auto dir = buildPath(segments[0..i+1]);
						if (array(map!`a.name`(dirEntries(dir, SpanMode.shallow))).length==0)
							rmdir(dir);
					}
				}
			}
		}
}

// Basic test
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo");
	main(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/test.txt") == "bar");
}

// Test renaming parent directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/x.txt", "foo");
	main(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/x.txt") == "bar");
}

// Renamed empty directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/foo.txt", "foo");
	main(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/bar.txt") == "bar");
}

// Renaming specified directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/foo.txt", "foo");
	main(["greplace", "foo", "bar", dir ~ "/foo"]);
	assert(readText(dir ~ "/bar/bar.txt") == "bar");
}

mixin main!(funopt!greplace);
