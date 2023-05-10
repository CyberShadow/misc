#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/**
   Parse some D regular expressions from the command line.
   For each line read from stdin, display the match result against those expressions.
*/

import std.algorithm.iteration;
import std.array;
import std.exception;
import std.regex;
import std.stdio;
import std.string;

import ae.utils.funopt;
import ae.utils.main;

void dTestRE(string[] regexps)
{
	auto res = regexps.map!regex.array;
	while (!stdin.eof)
	{
		auto line = stdin.readln().chomp();
		foreach (i, re; res)
		{
			if (i) write("\t");
			auto m = matchFirst(line, re);
			if (m)
				write(m.array);
			else
				write("(no match)");
		}
		writeln;
	}
}

mixin main!(funopt!dTestRE);
