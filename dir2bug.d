#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/// Convert some text files into a text format suitable for pasting in
/// an issue tracker.

/// With --script, generate a simple shell script that recreates the
/// files.

module dir2bug;

import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

enum Mode
{
	pretty,
	bash,
}

void dir2bug(bool script, string[] files)
{
	Mode mode = script ? Mode.bash : Mode.pretty;

	size_t maxWidth = 0;
	if (mode == Mode.pretty)
		foreach (arg; files)
			foreach (s; File(arg, "rb").byLine(KeepTerminator.yes))
				maxWidth = max(maxWidth, s.stripRight().replace("\t", "    ").length);

	final switch (mode)
	{
		case Mode.pretty:
			break;
		case Mode.bash:
			writeln("#!/usr/bin/env bash");
			writeln();
			break;
	}

	bool[string] dirsCreated;
	dirsCreated["."] = true;

	foreach (arg; files)
	{
		string s = readText(arg);
		final switch (mode)
		{
			case Mode.pretty:
			{
				auto header = "// %s //".format(arg);
				while (header.length < maxWidth)
				{
					header = "/" ~ header;
					if (header.length < maxWidth)
						header ~= "/";
				}
				writeln(header);
				break;
			}
			case Mode.bash:
			{
				auto dir = dirName(arg);
				if (dir !in dirsCreated)
				{
					bool needParents = false;
					for (auto pdir = dirName(dir); pdir != "."; pdir = dirName(pdir))
						if (pdir !in dirsCreated)
						{
							needParents = true;
							dirsCreated[pdir] = true;
						}
					dirsCreated[dir] = true;
					writefln("mkdir%s %s", needParents ? " -p" : "", maybeEscapeShellFileName(dir));
				}

				auto fn = maybeEscapeShellFileName(arg);
				if (s == "")
				{
					writefln("touch %s", fn);
					continue;
				}
				if (s.endsWith("\n") && !s.chomp("\n").contains('\n') && !s.contains('\''))
				{
					writefln("echo '%s' > %s", s.chomp("\n"), fn);
					continue;
				}
				writefln("cat > %s <<'EOF'", fn);
				break;
			}
		}

		s = s.replace("\t", "    ");
		stdout.rawWrite(s);
		if (!s.endsWith("\n"))
			writeln();

		final switch (mode)
		{
			case Mode.pretty:
				break;
			case Mode.bash:
				writeln("EOF");
				writeln();
				break;
		}
	}
	final switch (mode)
	{
		case Mode.pretty:
			writeln("/".replicate(maxWidth));
			break;
		case Mode.bash:
			break;
	}
}

string maybeEscapeShellFileName(string s)
{
	foreach (c; s)
		if ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_/".indexOf(c) < 0)
			return escapeShellFileName(s);
	return s;
}

mixin main!(funopt!dir2bug);
