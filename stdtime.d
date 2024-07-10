#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Convert D standard time timestamps into
   human-readable calendar date/time, and back.
 */

module stdtime;

import std.conv;
import std.datetime.systime;
import std.stdio;

import ae.utils.time;
import ae.utils.time.format;

void main(string[] args)
{
mainLoop:
	foreach (arg; args[1..$])
		try
		{
			auto time = arg.to!StdTime;
			writeln(SysTime(time).formatTime!"Y-m-d H:i:s.9");
		}
		catch (Exception e)
		{
			foreach (format; [
					TimeFormats.ATOM,
					TimeFormats.COOKIE,
					TimeFormats.ISO8601,
					TimeFormats.RFC822,
					TimeFormats.RFC850,
					TimeFormats.RFC1036,
					TimeFormats.RFC1123,
					TimeFormats.RFC2822,
					TimeFormats.RFC3339,
					TimeFormats.RSS,
					TimeFormats.W3C,
					TimeFormats.CTIME,
					TimeFormats.HTML5DATE,
					TimeFormats.STD_DATE,
					"Y.m.d H:i:s.E",
					"Y-m-d H:i:s.E",
					"Y-m-d H:i:s.u",
					"Y-m-d H:i:s.9",
					"Y-m-d H:i:s.v",
					"Y-m-d H:i:s",
				])
				try
				{
					writeln(arg.parseTimeUsing(format).stdTime);
					continue mainLoop;
				}
				catch (Exception e)
				{}
			throw new Exception("Unrecognized time format: " ~ arg);
		}
}
