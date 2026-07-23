#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Send stdin lines to stdout, prefixed with timestamps.

   Like ts from the moreutils package.
*/

module ts;

import std.stdio;
import std.datetime;

import ae.utils.time;

// Disable parallel GC marking to avoid a livelock in druntime
// (https://github.com/dlang/dmd/pull/23082) which its background scan
// threads are prone to given this program's tiny root set / shallow heap.
extern(C) __gshared string[] rt_options = ["gcopt=parallel:0"];

void main()
{
	stdin.setvbuf(1024, _IOLBF);
	while (!stdin.eof)
	{
		auto s = stdin.readln();
		if (s.length) { write(formatTime("[Y-m-d H:i:s.E] ", Clock.currTime()), s); stdout.flush(); }
	}
}
