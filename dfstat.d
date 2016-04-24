import std.datetime;
import std.file;
import std.stdio;

import ae.utils.time.format;

void main(string[] args)
{
	foreach (arg; args[1..$])
	{
		auto entry = DirEntry(arg);
		void printTime(string name, SysTime time)
		{
			writefln("%s: %s (%s)", name, time.formatTime!`Y-m-d H:i:s.u`(), time.stdTime);
		}
		writefln("  Size: %d", entry.size);
		printTime("Access", entry.timeLastAccessed());
		printTime("Modify", entry.timeLastModified());
		printTime("Change", entry.timeStatusChanged());
	}
}
