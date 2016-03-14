module cp_btrfs_dedup;

import etc.linux.memoryerror;

import std.file;
import std.mmfile;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.btrfs.clone_range;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;

enum blockSize = 16*1024;

alias hashFun = murmurHash3_x64_128;
alias Hash = MH3Digest128;

void btrfs_dedup_cp(string src, string dst)
{
	auto srcFile = File(src, "rb");
	auto dstFile = File(dst, "wb");
	auto srcMM = new MmFile(srcFile);
	srcMM[]; // map entire file

	void[] getBlock(ulong n)
	{
		return srcMM[n * blockSize .. (n+1) * blockSize];
	}

	ulong matchA, matchB; /// Clone source, target
	ulong[Hash] blocks; /// Duplicate block lookup

	ulong extents, totalBlocks, uniqueBlocks; /// Statistics

	void flush(ulong end)
	{
		auto length = end - matchB;
		if (length)
		{
			extents++;
			totalBlocks += length;
			uniqueBlocks += matchA == matchB ? length : 0;
			cloneRange(
				srcFile, matchA * blockSize,
				dstFile, matchB * blockSize,
				length * blockSize);
		}
		matchA = matchB = end;
	}

	void status(bool done)(ulong current)
	{
		stderr.writef("[%3d%%] Clon%s %d/%d blocks to %d extents with %d/%d unique blocks %s",
			current * 100 / blockCount, done ? "ed" : "ing", current, blockCount, extents, uniqueBlocks, totalBlocks,
			done ? "\n" : "\r");
		stderr.flush();
	}

	auto blockCount = srcMM.length / blockSize;
	foreach (i; 0 .. blockCount)
	{
		if (i % 1024 == 0)
			status!false(i);

		auto block = getBlock(i);
		Hash hash = hashFun(block);
		auto pBlock = hash in blocks;
		if (!pBlock)
			blocks[hash] = i;

		if (matchA == matchB) // just copying
		{
			if (pBlock && getBlock(*pBlock) == block) // match found?
			{
				flush(i); // stop copying, start cloning
				matchA = *pBlock;
				matchB = i;
			}
		}
		else // cloning
		{
			auto matchIndex = i - matchB;
			auto indexA = matchA + matchIndex;
			if (getBlock(indexA) == block) // can we keep cloning?
				continue;

			flush(i); // start copying
			matchA = matchB = i;

			if (pBlock && getBlock(*pBlock) == block) // or cloning, if we can
				matchA = *pBlock;
		}
	}

	flush(blockCount);

	dstFile.seek(blockCount * blockSize);
	dstFile.rawWrite(srcMM[blockCount * blockSize .. srcFile.size]);

	status!true(blockCount);
}

mixin main!(funopt!btrfs_dedup_cp);
