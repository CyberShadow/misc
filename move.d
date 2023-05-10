#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/// Thin wrapper around rename(2).
/// Unlike mv(1), never attempts to read the file contents.

import ae.utils.funopt;
import ae.utils.main;

void move(string source, string target)
{
	static import std.file;
	std.file.rename(source, target);
}

mixin main!(funopt!move);
