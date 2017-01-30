module convert;

import std.array;
import std.conv;
import std.stdio;

void main()
{
	foreach (line; stdin.byLine)
	{
		auto parts = line.split(";");
		writefln("%c - %s", cast(dchar)(parts[0].to!int(16)), parts[1]);
	}
}
