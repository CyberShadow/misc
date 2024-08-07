#!/usr/bin/env dub
/+ dub.sdl: +/

/// Used by ~/libexec/unicode-character-menu to convert UnicodeData.txt
/// into something usable by rofi.

module convert;

import std.array;
import std.conv;
import std.stdio;
import std.utf;

void main()
{
	foreach (line; stdin.byLine)
	{
		auto parts = line.split(";");
		try
			writefln("%c - U+%s %s", cast(dchar)(parts[0].to!int(16)), parts[0], parts[1]);
		catch (UTFException)
			continue;
	}
}
