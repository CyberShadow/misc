/**
   Send stdin lines to stdout, prefixed with timestamps.

   Like ts from the moreutils package.
*/

module ts;

import std.stdio;
import std.datetime;

import ae.utils.time;

void main()
{
	stdin.setvbuf(1024, _IOLBF);
	while (!stdin.eof)
	{
		auto s = stdin.readln();
		if (s.length) { write(formatTime("[Y-m-d H:i:s.E] ", Clock.currTime()), s); stdout.flush(); }
	}
}
