import std.stdio;

import ae.sys.datamm;
import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text;

int hexgrep(string hexPattern, string[] files)
{
	auto pattern = arrayFromHex(hexPattern);

	bool found;
	foreach (fn; files)
	{
		auto data = mapFile(fn, MmMode.read);
		auto contents = cast(ubyte[])data.contents;
		size_t start = 0;
		sizediff_t p;
		while ((p = contents[start .. $].indexOf(pattern)) >= 0)
		{
			writefln("%s: %08x", fn, start + p);
			start += p + 1;
			found = true;
		}
	}
	return found ? 0 : 1;
}

mixin main!(funopt!hexgrep);
