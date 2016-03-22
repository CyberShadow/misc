import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.getopt;
import std.path;
import std.range;
import std.stdio;
import std.string;

void main(string[] args)
{
	bool force;
	getopt(args,
		"f", &force);

	if (args.length != 3)
		throw new Exception("Usage: " ~ args[0] ~ " [-f] <from> <to>");
	auto from = cast(ubyte[])args[1], to = cast(ubyte[])args[2];
	auto fromw = cast(ubyte[])std.conv.to!wstring(args[1]), tow = cast(ubyte[])std.conv.to!wstring(args[2]);

	auto files = array(map!`a.name`(dirEntries("", SpanMode.breadth)));
	if (!force)
	{
		foreach (file; files)
			if (isFile(file))
			{
				auto data = cast(ubyte[])std.file.read(file);
				if (data.countUntil(to)>=0)
					throw new Exception("File " ~ file ~ " already contains " ~ args[2]);
				if (data.countUntil(tow)>=0)
					throw new Exception("File " ~ file ~ " already contains " ~ args[2] ~ " (in UTF-16)");
			}
	}

	foreach (file; files)
	{
		if (isFile(file))
		{
			auto s = cast(ubyte[])std.file.read(file);
			bool modified = false;
			if (s.countUntil(from)>=0)
			{
				s = s.replace(from, to);
				modified = true;
			}
			if (s.countUntil(fromw)>=0)
			{
				s = s.replace(fromw, tow);
				modified = true;
			}
			if (modified)
			{
				writeln(file);
				std.file.write(file, s);
			}

			if (file.indexOf(args[1])>=0)
			{
				string newName = file.replace(args[1], args[2]);
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
}
