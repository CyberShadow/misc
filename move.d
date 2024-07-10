#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/// Thin wrapper around rename(2).
/// Unlike mv(1), never attempts to read the file contents.

import ae.utils.funopt;
import ae.utils.main;

void move(
	Switch!("Atomically exchange SOURCE and TARGET", 'e') exchange,
	Switch!("Do not overwrite an existing TARGET", 'n') noReplace,
	Switch!("Create a whiteout object", 'w') whiteout,
	string source,
	string target,
)
{
	version (linux)
	{
		import core.sys.posix.fcntl : AT_FDCWD;
		import core.sys.linux.fs : RENAME_EXCHANGE, RENAME_NOREPLACE, RENAME_WHITEOUT;
		import std.exception : errnoEnforce;
		import std.string : toStringz;
		import ae.utils.math : eq;

		uint flags;
		if (exchange)
			flags |= RENAME_EXCHANGE;
		if (noReplace)
			flags |= RENAME_NOREPLACE;
		if (whiteout)
			flags |= RENAME_WHITEOUT;

		renameat2(
			AT_FDCWD, source.toStringz, 
			AT_FDCWD, target.toStringz,
			flags
		).eq(0).errnoEnforce("renameat2");
	}
	else
	{
		enforce(!exchange && !noReplace && !whiteout, "This option is only supported on Linux.");

		static import std.file;
		std.file.rename(source, target);
	}
}

version (linux)
{
	extern(C) int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, uint flags);
}


mixin main!(funopt!move);
