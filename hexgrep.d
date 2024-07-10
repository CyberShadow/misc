#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

import std.algorithm.comparison : min;
import std.parallelism;
import std.range;
import std.stdio;

import ae.sys.datamm;
import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text;

int hexgrep(
	Switch!(null, 'j') parallel,
	string hexPattern,
	string[] files,
)
{
	auto pattern = arrayFromHex(hexPattern);

	bool found;
	foreach (fn; files)
	{
		auto data = mapFile(fn, MmMode.read);
		auto contents = cast(ubyte[])data.contents;
		if (contents.length < pattern.length)
			continue;
		auto maxOffset = contents.length - pattern.length + 1;

		void search(size_t start, size_t end)
		{
			sizediff_t p;
			while ((p = contents[start .. end + pattern.length - 1].indexOf(pattern)) >= 0)
			{
				writefln("%s: %08x", fn, start + p);
				start += p + 1;
				found = true;
			}
		}
		if (!parallel)
			search(0, maxOffset);
		else
		{
			enum chunkSize = 1024*1024;
			auto numChunks = (maxOffset + chunkSize - 1) / chunkSize;
			foreach (chunkIndex; numChunks.iota.parallel(1))
				search(chunkIndex * chunkSize, min((chunkIndex + 1) * chunkSize, maxOffset));
		}

	}
	return found ? 0 : 1;
}

mixin main!(funopt!hexgrep);
