#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

import std.stdio;

import ae.sys.datamm;
import ae.sys.file;

void process(in void[] data)
{
	auto bytes = cast(ubyte[])data;
	auto buf = new ubyte[bytes.length];
	size_t p;
	for (size_t i = 0; i < bytes.length ; i+=2)
		buf[p++] = bytes[i];
	for (size_t i = 1; i < bytes.length ; i+=2)
		buf[p++] = bytes[i];
	stdout.rawWrite(buf);
}

void main(string[] args)
{
	auto files = args[1..$];
	if (files.length == 0)
		process(readFile(stdin));
	else
		foreach (fn; files)
		{
			auto d = mapFile(fn, MmMode.read);
			process(d.contents);
		}
}
