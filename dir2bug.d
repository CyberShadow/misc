import ae.utils.funopt;
import ae.utils.main;

import std.algorithm;
import std.array;
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
			writeln("#!/bin/bash");
			writeln();
			break;
	}

	bool[string] dirsCreated;
	dirsCreated["."] = true;

	foreach (arg; files)
	{
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

				writefln("cat > %s <<'EOF'", maybeEscapeShellFileName(arg));
				break;
			}
		}

		bool wasEOL;
		foreach (s; File(arg, "rb").byLine(KeepTerminator.yes))
		{
			wasEOL = s.endsWith("\n");
			stdout.rawWrite(s.replace("\t", "    "));
		}
		if (!wasEOL)
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
