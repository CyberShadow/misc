#!/usr/bin/env dub
/+ dub.sdl: +/

/**
   Debug tool; prints environment and arguments.
*/

module printenv;

import std.ascii;
import std.file;
import std.getopt;
import std.process;
import std.stdio;
import std.string;

void main(string[] args)
{
	stderr.writeln("Arguments:");
	foreach (arg; args)
		stderr.writeln(arg);

	stderr.writeln("Environment:");
	foreach (name, value; environment.toAA)
		stderr.writefln("%s=%s", name, value);
}
