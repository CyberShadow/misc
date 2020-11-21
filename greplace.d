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

	auto files = targets.map!(target => target.empty || target.isDir ? dirEntries(target, SpanMode.breadth, followSymlinks).array : [DirEntry(target)]).join();
	if (!force)
	{
		foreach (ref file; files)
		{
			if (!noContent)
			{
				ubyte[] s;
				if (file.isSymlink())
					s = cast(ubyte[])readLink(file.name);
				else
				if (file.isFile())
					s = cast(ubyte[])std.file.read(file.name);

				if (s)
				{
					if (s.countUntil(to)>=0)
						throw new Exception("File " ~ file.name ~ " already contains " ~ toStr);
					if (wide && s.countUntil(tow)>=0)
						throw new Exception("File " ~ file.name ~ " already contains " ~ toStr ~ " (in UTF-16)");
				}
			}

			if (file.name.indexOf(toStr)>=0)
				throw new Exception("File name " ~ file.name ~ " already contains " ~ toStr);
		}
	}

	foreach (ref file; files)
	{
		if (!noContent)
		{
			ubyte[] s;
			if (file.isSymlink())
				s = cast(ubyte[])readLink(file.name);
			else
			if (file.isFile())
				s = cast(ubyte[])std.file.read(file.name);

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
							remove(file.name);
							symlink(cast(string)s, file.name);
						}
						else
						if (file.isFile())
							std.file.write(file.name, s);
						else
							assert(false);
					}
				}
			}
		}

		if (file.name.indexOf(fromStr)>=0)
		{
			string newName = file.name.replace(fromStr.value, toStr.value);
			writeln(file.name, " -> ", newName);

			if (!dryRun)
			{
				if (!exists(dirName(newName)))
					mkdirRecurse(dirName(newName));
				std.file.rename(file.name, newName);

				// TODO: empty folders

				auto segments = array(pathSplitter(file.name))[0..$-1];
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

mixin main!(funopt!greplace);
