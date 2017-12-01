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

void greplace(bool force, bool wide, bool noContent, string fromStr, string toStr, string[] targets = null)
{
	if (!targets.length)
		targets = [""];

	ubyte[] from, to, fromw, tow;
	from = cast(ubyte[])fromStr;
	to   = cast(ubyte[])toStr;

	if (wide)
	{
		fromw = cast(ubyte[])std.conv.to!wstring(fromStr);
		tow   = cast(ubyte[])std.conv.to!wstring(toStr);
	}

	auto files = targets.map!(target => target.empty || target.isDir ? dirEntries(target, SpanMode.breadth).map!`a.name`().array : [target]).join();
	if (!force)
	{
		foreach (file; files)
		{
			ubyte[] data;
			if (file.isSymlink())
				data = cast(ubyte[])readLink(file);
			else
			if (file.isFile())
				data = cast(ubyte[])std.file.read(file);
			else
				continue;

			if (!noContent)
			{
				if (data.countUntil(to)>=0)
					throw new Exception("File " ~ file ~ " already contains " ~ toStr);
				if (wide && data.countUntil(tow)>=0)
					throw new Exception("File " ~ file ~ " already contains " ~ toStr ~ " (in UTF-16)");
			}
		}
	}

	foreach (file; files)
	{
		if (!noContent)
		{
			ubyte[] s;
			if (file.isSymlink())
				s = cast(ubyte[])readLink(file);
			else
			if (file.isFile())
				s = cast(ubyte[])std.file.read(file);
			else
				continue;

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
				writeln(file);

				if (file.isFile())
					std.file.write(file, s);
				else
				if (file.isSymlink())
				{
					remove(file);
					symlink(cast(string)s, file);
				}
				else
					assert(false);
			}
		}

		if (file.indexOf(fromStr)>=0)
		{
			string newName = file.replace(fromStr, toStr);
			writeln(file, " -> ", newName);
	
			if (!exists(dirName(newName)))
				mkdirRecurse(dirName(newName));
			std.file.rename(file, newName);
	
			// TODO: empty folders

			auto segments = array(pathSplitter(file))[0..$-1];
			foreach_reverse (i; 0..segments.length)
			{
				auto dir = buildPath(segments[0..i+1]);
				if (array(map!`a.name`(dirEntries(dir, SpanMode.shallow))).length==0)
					rmdir(dir);
			}	
		}
	}
}

mixin main!(funopt!greplace);
