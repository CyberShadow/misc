module btrfs_dedup_tail;

import etc.linux.memoryerror;
import core.thread;

import std.exception;
import std.file;
import std.path;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.btrfs.extent_same;
import ae.sys.file;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;

enum blockSize = 16*1024;

void btrfs_dedup_tail(string srcFile, string dstFile)
{
	auto fSrc = File(srcFile, "rb");
	auto fDst = File(dstFile, "rb");

	auto bufSrc = new ubyte[blockSize];
	auto bufDst = new ubyte[blockSize];

	bool deduplicating = false;
	ulong start, pos = 0;

	/// Deduplicate from start to pos
	void flush()
	{
		auto result = sameExtent([
				Extent(fSrc, start),
				Extent(fDst, start),
			], pos - start);
		stderr.writefln(" >> %d bytes deduped", result.totalBytesDeduped);
	}

	auto size = fSrc.size; // assume constant

	while (pos + blockSize <= size)
	{
		if (pos + blockSize > fDst.size)
		{
			stderr.writeln("Waiting...");
			do
				Thread.sleep(1.seconds);
			while (pos + blockSize > fDst.size);
		}

		stderr.writefln("%d/%d (%3d%%) [%s]", pos, size, pos * 100 / size, deduplicating ? "s" : "d");

		auto readSrc = fSrc.rawRead(bufSrc[]);
		enforce(readSrc.length == blockSize, "Unexpected end of source file");
		auto readDst = fDst.rawRead(bufDst[]);
		enforce(readDst.length == blockSize, "Unexpected end of target file");

		if (readSrc == readDst)
		{
			if (!deduplicating)
			{
				stderr.writefln(" >> Entering duplicate region");
				deduplicating = true;
				start = pos;
			}
		}
		else
		{
			if (deduplicating)
			{
				flush();
				deduplicating = false;
			}
		}

		pos += blockSize;
	}

	if (deduplicating)
		flush();
}

mixin main!(funopt!btrfs_dedup_tail);
