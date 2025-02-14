#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Convert a CSV file (with a header) to a JSON array of homogeneous objects.
*/

import std.algorithm.iteration;
import std.array;
import std.csv;
import std.exception;
import std.range;
import std.stdio;
import std.string : assumeUTF;
import std.typecons : tuple;

import ae.sys.file : readFile;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.json;
import ae.utils.main;

void program()
{
	auto lines = stdin
		.readFile()
		.assumeUTF
		.csvReader;
	if (lines.empty)
	{
		null.toJson.writeln();
		return;
	}

	auto headers = lines.front.array;
	lines.popFront(); // https://github.com/dlang/phobos/issues/10636
	lines
		.map!(line => line.array)
		.map!(line => line.length
			.iota
			.map!(i => tuple(headers[i], line[i]))
			.orderedMap
		)
		.array
		.toJson
		.writeln();
}

mixin main!(funopt!program);
