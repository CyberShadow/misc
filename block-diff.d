/// Produce a block-by-block diff (consumable by block-patch)
/// between two block devices or binary files.
/// The files should have the same size.

module block_diff;

import std.exception;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.utils.funopt;
import ae.utils.main;

enum defaultBlockSize = 4*1024;

void block_diff(
	string oldFile,
	string newFile,
	string outFile = null,
	size_t blockSize = defaultBlockSize,
)
{
	auto fOld = File(oldFile, "rb");
	auto fNew = File(newFile, "rb");
	auto fOut = outFile ? File(outFile, "wb") : stdout;

	auto bufOld = new ubyte[blockSize];
	auto bufNew = new ubyte[blockSize];

	ulong size, pos = 0, diffBlocks = 0, totalBlocks = 0;
	try
		size = fOld.size;
	catch (Exception e)
		size = ulong.max;

	while (true)
	{
		if (size == ulong.max)
			stderr.writef("%d\r"           , pos,                       );
		else
			stderr.writef("%d/%d (%3d%%)\r", pos, size, pos * 100 / size);
		stderr.flush();

		auto readOld = fOld.rawRead(bufOld[]);
		if (readOld.length == 0)
			break;
		auto readNew = fNew.rawRead(bufNew[0 .. readOld.length]);
		enforce(readNew.length == readOld.length, "Unexpected end of new file");

		if (readOld != readNew)
		{
			fOut.writeln(pos, " ", readOld.length);
			fOut.rawWrite(readNew);
			diffBlocks++;
		}

		pos += readOld.length;
		totalBlocks++;
	}
	stderr.writeln();
	stderr.writefln("%d/%d differing blocks.", diffBlocks, totalBlocks);
}

mixin main!(funopt!block_diff);
