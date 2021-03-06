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

import std.algorithm.iteration;
import std.array;
import std.exception;
import std.file;
import std.mmfile;
import std.path;
import std.range;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.btrfs.extent_same;
import ae.sys.file;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;

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

/// Used to print relative paths to found files
string[] roots;

struct SubPath
{
	size_t index; /// Original argument index (for roots array)
	DirEntry de;
}

void scan(SubPath[] paths)
{
	paths = paths.filter!(path => !path.de.isSymlink).array;
	if (paths.length <= 1)
		return;

	auto dirs = paths.filter!(path => path.de.isDir).array;
	if (dirs.length >= 2)
	{
		DirEntry[size_t][string] names;
		foreach (dir; dirs)
			foreach (de; dirEntries(dir.de, SpanMode.shallow))
				names[de.baseName][dir.index] = de;
		foreach (name, entries; names)
			if (entries.length > 1)
				scan(entries.byKeyValue.map!(kv => SubPath(kv.key, kv.value)).array);
	}

	auto files = paths.filter!(path => path.de.isFile).array;
	if (files.length >= 2)
	{
		foreach (file1; files[1..$])
		{
			if (files[0].de.size != file1.de.size)
				return;
			stderr.writeln(files[0].de.absolutePath.relativePath(roots[files[0].index].absolutePath));
			dedupFile(files[0].de, file1.de);
		}
	}
}


void btrfs_dedup_tree(string[] dirs)
{
	enforce(dirs.length, "You must specify at least one directory");
	roots = dirs;
	scan(dirs.enumerate.map!(dir => SubPath(dir.index, DirEntry(dir.value))).array);
}

mixin main!(funopt!btrfs_dedup_tree);
