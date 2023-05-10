#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/// Read a binary diff (produced by block-diff)
/// and apply it to a file or block device.

module block_patch;

import std.exception;
import std.format;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.utils.funopt;
import ae.utils.main;

void block_patch(
	string targetFile,
	string patchFile = null,
)
{
	auto fTarget = File(targetFile, "r+b");
	auto fPatch = patchFile ? File(patchFile, "rb") : stdin;

	ubyte[] buf;

	ulong targetSize, patchSize;
	try
		targetSize = fTarget.size;
	catch (Exception e)
		targetSize = ulong.max;
	try
		patchSize = fPatch.size;
	catch (Exception e)
		patchSize = ulong.max;

	ulong numChunks;

	while (!fPatch.eof)
	{
		auto s = fPatch.readln;
		if (!s.length)
			continue; // eof?
		ulong offset, size;
		enforce(formattedRead!"%d %d\n"(s, offset, size) == 2, "Could not parse patch chunk header: " ~ s);

		if (patchSize != ulong.max)
			if (targetSize != ulong.max)
				stderr.writef("Patching %3d%% @ %3d%%\r", fPatch.tell * 100 / patchSize, fTarget.tell * 100 / targetSize);
			else
				stderr.writef("Patching %3d%%\r"        , fPatch.tell * 100 / patchSize);
		else
			if (targetSize != ulong.max)
				stderr.writef("Patching @ %3d%%\r"      ,                                fTarget.tell * 100 / targetSize);
			else
				stderr.writef("Patching chunk %d\r", numChunks);
		
		if (buf.length < size)
			buf.length = size;
		auto readBuf = fPatch.rawRead(buf[0 .. size]);
		enforce(readBuf.length == size, "Unexpected end of patch file");
		fTarget.seek(offset);
		fTarget.rawWrite(readBuf);
		numChunks++;
	}
	stderr.writeln();
	stderr.writeln("Flushing...");
	fTarget.close();
	fPatch.close();
	stderr.writefln("Done - patched %d chunks.", numChunks);
}

mixin main!(funopt!block_patch);
