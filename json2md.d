#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Convert a JSON array of homogeneous objects to a Markdown (GFM) table.
*/

import std.algorithm.iteration;
import std.array;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.json;
import ae.utils.main;

void program()
{
	auto data = readFile(stdin).assumeUTF.jsonParse!(OrderedMap!(string, string)[]);
	if (!data.length)
		return;
	auto keys = data[0].keys;
	writefln("| %-(%s |%| %)", keys.map!mdEscape);
	writefln("| %-(%s |%| %)", keys.map!(s => "-"));
	foreach (row; data)
		writefln("| %-(%s |%| %)", keys.map!(key => row[key]).map!mdEscape);
}

mixin main!(funopt!program);

string mdEscape(string s) {
	if (!s.length)
		return "";
	size_t numQuotes, maxNumQuotes;
	foreach (c; s)
		if (c == '`')
		{
			numQuotes++;
			if (numQuotes > maxNumQuotes)
				maxNumQuotes = numQuotes;
		}
		else
			numQuotes = 0;
	auto delimiter = "`".replicate(maxNumQuotes + 1);
	return delimiter ~ s ~ delimiter;
}
