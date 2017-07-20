/**
   Compare two directory trees. When a file exists at the same
   sub-path in both trees, deduplicate identical blocks within the
   file.

   Useful when you have mostly-identical directory trees, but
   brute-force full deduplication (e.g. using duperemove) is too slow.

   When the source or target already have shared extents, mind the
   deduplication direction, as btrfs will not merge all
   references. E.g. if you have files A B C D pointing to physical
   blocks 1 1 2 2 respectively, deduplicating B and C will likely
   result in 1 1 1 2 or 1 2 2 2, not 1 1 1 1.
*/

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

	auto pos = 0;
	auto size = fA.size;
	while (pos < size)
	{
		auto result = sameExtent([
				Extent(fA, pos),
				Extent(fB, pos),
			], size - pos);
		stderr.writefln(" >> %d bytes deduped at %d", result.totalBytesDeduped, pos);
		pos += result.totalBytesDeduped;
	}
}

void scanDir(string subdirA, string subdirB)
{
	foreach (deA; dirEntries(subdirA, SpanMode.shallow))
	{
		auto pathB = subdirB.buildPath(deA.baseName);
		if (!pathB.exists)
			continue;
		auto deB = DirEntry(pathB);
		scan(deA, deB);
	}
}

string rootA;

void scan(DirEntry deA, DirEntry deB)
{
	if (deA.isSymlink || deB.isSymlink)
		return;
	if (deA.isDir)
		scanDir(deA.name, deB.name);
	else
	if (deA.isFile && deB.isFile)
	{
		if (deA.size != deB.size)
			return;
		stderr.writeln(deA.absolutePath.relativePath(rootA.absolutePath));
		dedupFile(deA, deB);
	}
}


void btrfs_dedup_tree(string dirA, string dirB)
{
	rootA = dirA;
	scan(DirEntry(dirA), DirEntry(dirB));
}

mixin main!(funopt!btrfs_dedup_tree);
