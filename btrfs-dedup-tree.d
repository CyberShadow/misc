#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Compare two or more directory trees. When a file exists at the same
   sub-path in multiple trees, deduplicate identical blocks within the
   file.

   Useful when you have mostly-identical directory trees, but
   brute-force full deduplication (e.g. using duperemove) is too slow.

   Deduplication follows command-line argument order, like tools which
   take source arguments before target arguments. When the same relative
   path and file size exists under multiple directory arguments, the
   leftmost matching file is the source extent and later matching files
   are deduplicated to it.

   When the source or target already have shared extents, mind the
   deduplication direction, as btrfs will not merge all
   references. E.g. if you have files A B C D pointing to physical
   blocks 1 1 2 2 respectively, deduplicating B and C will likely
   result in 1 1 1 2 or 1 2 2 2, not 1 1 1 1.
*/

module btrfs_dedup_tree;

import etc.linux.memoryerror;

import std.algorithm.iteration;
import std.algorithm.sorting;
import std.array;
import std.exception;
import std.file;
import std.mmfile;
import std.path;
import std.range;
import std.stdio;

// ae is https://github.com/CyberShadow/ae
import ae.sys.btrfs.extent_same;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.path : relPath;

void dedupFile(string srcPath, string dstPath)
{
	auto fSrc = File(srcPath, "rb");
	auto fDst = File(dstPath, "rb");
	if (fSrc.size != fDst.size)
		return;

	size_t pos = 0;
	size_t size = fSrc.size;
	while (pos < size)
	{
		Extent[2] extents = [
			Extent(fSrc, pos),
			Extent(fDst, pos),
		];
		try
		{
			auto result = sameExtent(extents, size - pos);
			stderr.writefln(" >> %d bytes deduped at %d", result.totalBytesDeduped, pos);
			pos += result.totalBytesDeduped;
		}
		catch (Exception e)
		{
			stderr.writefln(" >> %s", e.msg);
			return;
		}
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
		foreach (name; names.keys.sort)
		{
			auto entries = names[name];
			if (entries.length > 1)
				scan(entries.keys.sort.map!(index => SubPath(index, entries[index])).array);
		}
	}

	auto files = paths.filter!(path => path.de.isFile).array;
	if (files.length >= 2)
	{
		DirEntry[size_t][ulong] sizes;
		foreach (file; files)
			sizes[file.de.size][file.index] = file.de;
		foreach (size, entries; sizes)
			if (entries.length > 1)
			{
				auto indices = entries.keys.sort;
				auto srcIndex = indices.front;
				auto srcEntry = entries[srcIndex];
				stderr.writeln(srcEntry.relPath(roots[srcIndex]));
				foreach (dstIndex; indices.dropOne)
					dedupFile(srcEntry, entries[dstIndex]);
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
