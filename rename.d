/// Thin wrapper around rename(2).
/// Unlike mv(1), never attempts to read the file contents.

import ae.utils.funopt;
import ae.utils.main;

void rename(string source, string target)
{
	static import std.file;
	std.file.rename(source, target);
}

mixin main!(funopt!rename);
