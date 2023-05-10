#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/**
   Apply a sed-like search-and-replace transform over the target of a
   symbolic link.

   Can be used to update a large number of symbolic links at once.
*/

import std.exception;
import std.file;
import std.stdio;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.regex;

void relink(bool dryRun, string pattern, string[] files)
{
	foreach (file; files)
		enforce(file.isSymlink(), file ~ " is not a symbolic link");

	foreach (file; files)
	{
		auto oldTarget = file.readLink();
		auto newTarget = oldTarget.applyRE(pattern);
		if (oldTarget != newTarget)
		{
			writefln("%s: %s -> %s", file, oldTarget, newTarget);
			if (!dryRun)
			{
				remove(file);
				symlink(newTarget, file);
			}
		}
	}
}

mixin main!(funopt!relink);
