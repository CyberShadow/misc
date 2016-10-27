import std.exception;
import std.file;
import std.stdio;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.regex;

void relink(string pattern, string[] files)
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
			remove(file);
			symlink(newTarget, file);
		}
	}
}

mixin main!(funopt!relink);
