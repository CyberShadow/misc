module btrfs_dedup_tree;

import etc.linux.memoryerror;

import std.file;
import std.mmfile;
import std.path;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.btrfs.extent_same;
import ae.sys.file;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;

enum blockSize = 16*1024;

void dedupFile(string pathA, string pathB)
{
	if (mdFile(pathA) != mdFile(pathB))
		return;

	auto fA = File(pathA, "rb");
	auto fB = File(pathB, "rb");

	auto result = sameExtent([
			Extent(fA, 0),
			Extent(fB, 0),
		], fA.size);
	stderr.writefln(" >> %d bytes deduped", result.totalBytesDeduped);
}

void btrfs_dedup_tree(string dirA, string dirB)
{

	void scan(string subdirA, string subdirB)
	{
		foreach (deA; dirEntries(subdirA, SpanMode.shallow))
		{
			auto pathB = subdirB.buildPath(deA.baseName);
			if (!pathB.exists)
				continue;
			auto deB = DirEntry(pathB);
			if (deA.isSymlink || deB.isSymlink)
				continue;
			if (deA.isDir)
				scan(deA, pathB);
			else
			if (deA.isFile && deB.isFile)
			{
				if (deA.size != deB.size)
					continue;
				stderr.writeln(deA.absolutePath.relativePath(dirA));
				dedupFile(deA, deB);
			}
		}
	}

	scan(dirA, dirB);
}

mixin main!(funopt!btrfs_dedup_tree);
