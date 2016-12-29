module clobber_unreadable;

import etc.linux.memoryerror;
import core.thread;

import std.exception;
import std.file;
import std.path;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.file;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;

enum defaultBlockSize = 16*1024;

void clobberUnreadable(string fileName, size_t blockSize = defaultBlockSize, ubyte replacementByte = 0x00)
{
	auto f = File(fileName, "r+b");

	auto buf = new ubyte[blockSize];
	auto replacementBuf = new ubyte[blockSize];
	replacementBuf[] = replacementByte;

	auto progressInterval = 1024*1024 / blockSize;
	auto totalBlocks = f.size / blockSize;

	foreach (block; 0..totalBlocks)
	{
		if (block % progressInterval == 0)
		{
			stderr.writef("Reading block %d/%d (%d%%)...\r", block, totalBlocks, 100*block/totalBlocks);
			stderr.flush();
		}

		auto offset = block * blockSize;
		f.seek(offset);
		try
			f.rawRead(buf);
		catch (Exception e)
		{
			stderr.writefln("Replacing unreadable block #%d (at 0x%x)", block, offset);
			f.seek(offset);
			f.rawWrite(replacementBuf);
		}
	}
}

mixin main!(funopt!clobberUnreadable);
