/**
   A bit like dd, but uses the btrfs "clone" ioctl for efficient
   copies.
*/

module btrfs_dd;

import std.algorithm.searching;
import std.ascii;
import std.conv;
import std.exception;
import std.experimental.checkedint;
import std.functional;
import std.stdio;
import std.string;

// ae is https://github.com/CyberShadow/ae
import ae.sys.btrfs.clone_range;
import ae.utils.funopt;
import ae.utils.main;

enum blockSize = 16*1024;

void btrfs_dd(
	Option!(string, "Input file" , "FILE", 0, "if") inputFileName,
	Option!(string, "Output file", "FILE", 0, "of") outputFileName,
	Option!(string, "Block size", "SIZE", 0, "bs") blockSizeStr = "512",
	Option!(size_t, "Number of blocks to copy", "BLOCKS", 0, "count") count = size_t.max,
	Option!(size_t, "Blocks to skip in input", "BLOCKS", 0, "skip") inputOffset = 0,
	Option!(size_t, "Blocks to seek in output", "BLOCKS", 0, "seek") outputOffset = 0,
)
{
	auto fSrc = File(inputFileName, "rb");
	auto fDst = File(outputFileName, "r+b");

	auto blockSize = blockSizeStr.parseHumanSize();

	if (count == size_t.max)
		count = fSrc.size / blockSize - inputOffset;

	cloneRange(
		fSrc, inputOffset * blockSize,
		fDst, outputOffset * blockSize,
		count * blockSize
	);
}

ulong parseHumanSize(string str)
{
	auto n = str.parse!ulong().checked;
	auto pows = ["", "K", "M", "G", "T"].countUntil(
		str
		.find!(not!isWhite)
		.chomp("B")
		.chomp("i")
	);
	enforce(pows >= 0, "Unknown prefix: " ~ str);
	foreach (i; 0..pows)
		n *= 1024;
	return n.get();
}

void entry(string[] args)
{
	foreach (ref arg; args[1..$])
		if (!arg.startsWith("-"))
			arg = "--" ~ arg;
	funopt!btrfs_dd(args);
}

mixin main!entry;
