import std.algorithm;
import std.array;
import std.stdio;
import std.string;

void main(string[] args)
{
	size_t maxWidth = 0;
	foreach (arg; args[1..$])
		foreach (s; File(arg, "rb").byLine(KeepTerminator.yes))
			maxWidth = max(maxWidth, s.stripRight().replace("\t", "    ").length);

	foreach (arg; args[1..$])
	{
		auto header = "// %s //".format(arg);
		while (header.length < maxWidth)
		{
			header = "/" ~ header;
			if (header.length < maxWidth)
				header ~= "/";
		}
		writeln(header);

		bool wasEOL;
		foreach (s; File(arg, "rb").byLine(KeepTerminator.yes))
		{
			wasEOL = s.endsWith("\n");
			stdout.rawWrite(s.replace("\t", "    "));
		}
		if (!wasEOL)
			writeln();
	}
	writeln("/".replicate(maxWidth));
}
