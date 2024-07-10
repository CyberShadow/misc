#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Unpack an archive into a separate directory.
*/

import std.array;
import std.file;
import std.path;

import ae.sys.archive;
import ae.utils.funopt;
import ae.utils.main;

void unpack(string[] fileNames)
{
	foreach (fileName; fileNames)
	{
		auto dir = fileName.replace(".tar.", ".").stripExtension;
		mkdir(dir);
		ae.sys.archive.unpack(fileName, dir);
	}
}

mixin main!(funopt!unpack);
