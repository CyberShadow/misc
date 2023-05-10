#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
 dependency "chunker" version="==0.0.1"
+/

import std.algorithm.iteration;
import std.format;
import std.stdio;

import ae.utils.funopt;
import ae.utils.main;

import chunker;
import chunker.polynomials;

void chunkify(string[] files)
{
	foreach (fn; files)
	{
		size_t chunkIndex = 0;
		File(fn, "rb")
			.byChunk(1024*1024)
			.byCDChunk(Pol(0x3DA3358B4DC173))
			.each!(chunk => chunk.data.toFile(format("%s.chunk%04d", fn, chunkIndex++)));
	}
}

mixin main!(funopt!chunkify);
