/// Try to read a file, block by block.
/// If the read request fails, overwrite the failed block with data
/// from the same offset from another file.

module clobber_unreadable_with;

import etc.linux.memoryerror;
import core.thread;

import std.algorithm.comparison;
import std.exception;
import std.file;
import std.path;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.file;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;

enum defaultBlockSize = 4*1024;

void clobberUnreadableWith(string targetFileName, string sourceFileName, size_t blockSize = defaultBlockSize)
{
	auto tf = File(targetFileName, "r+b");
	auto sf = File(sourceFileName, "rb");

	auto buf = new ubyte[blockSize];

	if (tf.size > sf.size)
		stderr.writefln("Warning: target file is larger than source file, scanning only the common prefix");

	auto progressInterval = 1024*1024 / blockSize;
	auto totalBlocks = min(tf.size, sf.size) / blockSize;

	foreach (block; 0..totalBlocks)
	{
		if (block % progressInterval == 0)
		{
			stderr.writef("Reading block %d/%d (%d%%)...\r", block, totalBlocks, 100*block/totalBlocks);
			stderr.flush();
		}

		auto offset = block * blockSize;
		tf.seek(offset);
		try
			tf.rawRead(buf);
		catch (Exception e)
		{
			stderr.writefln("Replacing unreadable block #%d (at 0x%x)", block, offset);
			sf.seek(offset);
			sf.rawRead(buf);
			tf.seek(offset);
			tf.rawWrite(buf);
		}
	}
}

mixin main!(funopt!clobberUnreadableWith);
