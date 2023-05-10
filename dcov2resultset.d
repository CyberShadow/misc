#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/**
   Convert D coverage listings to a Ruby-like .resultset.json file.
*/

import std.algorithm.searching;
import std.datetime.systime;
import std.file;
import std.json;
import std.path;
import std.stdio;
import std.string;

import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;

void dcov2resultset(string[] files, Option!string resultName = "DCov")
{
	writefln(`{ %s: { "coverage": {`, JSONValue(resultName));
	foreach (fi, file; files)
	{
		auto lines = file.readText.splitLines;
		if (!lines.length) continue;
		auto fn = lines.stackPop.findSplit(" ")[0].absolutePath.buildNormalizedPath;
		writefln("  %s: [", JSONValue(fn));
		foreach (li, line; lines)
		{
			auto hits = line.findSplit("|")[0];
			write("    ");
			if (hits[0] == '0')
				write("0");
			else
			if (hits[$-1] == ' ')
				write("null");
			else
				write(hits.strip);
			if (li + 1 < lines.length)
				write(",");
			writeln;
		}
		write("  ]");
		if (fi + 1 < files.length)
			write(",");
		writeln;
	}
	writefln(`}, "timestamp": %d } }`, Clock.currTime.toUnixTime);
}

mixin main!(funopt!dcov2resultset);
