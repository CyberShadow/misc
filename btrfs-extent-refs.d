#!/usr/bin/env dub
/+ dub.sdl:
 dependency "btrfs" version="~>0.0.22"
+/

/**
   Print the btrfs file extents used by a file and the filesystem paths
   which reference each extent.

   The filesystem root used for path resolution must be the btrfs
   top-level subvolume. By default, this is the mount point containing
   the file. Use --fs-root when the file is reached through another
   subvolume mount.
*/

module btrfs_extent_refs;

import core.sys.posix.fcntl;
import core.sys.posix.sys.stat;
import core.sys.posix.unistd;

import std.algorithm.comparison;
import std.algorithm.sorting;
import std.array;
import std.exception;
import std.format;
import std.getopt;
import std.path;
import std.stdio;
import std.string;

import ae.sys.file : getPathMountInfo;

import btrfs;
import btrfs.c.ioctl : btrfs_ioctl_search_header;
import btrfs.c.kerncompat;
import btrfs.c.kernel_shared.ctree;

struct Root
{
	u64 parent;
	string path;
	bool found;
}

Root[u64] roots;

Root getRoot(int fd, u64 rootID)
{
	if (auto existing = rootID in roots)
		return *existing;

	Root result;
	findRootBackRef(
		fd,
		rootID,
		(
			u64 parentRootID,
			u64 dirID,
			u64 sequence,
			char[] name,
		) {
			cast(void) sequence;

			inoLookup(
				fd,
				parentRootID,
				dirID,
				(char[] dirPath)
				{
					enforce(!result.found, "Multiple root locations");
					result.parent = parentRootID;
					result.path = cast(string)(dirPath ~ name);
					result.found = true;
				},
			);
		},
	);

	if (result.found)
		cast(void)getRoot(fd, result.parent);

	roots[rootID] = result;
	return result;
}

string rootPath(int fd, string fsRoot, u64 rootID)
{
	auto root = getRoot(fd, rootID);
	if (!root.found)
	{
		enforce(rootID == BTRFS_FS_TREE_OBJECTID,
			format("Could not resolve root %d", rootID));
		return fsRoot;
	}

	return buildPath(rootPath(fd, fsRoot, root.parent), root.path);
}

string[] pathsForInode(int fd, string fsRoot, u64 rootID, u64 inode)
{
	auto root = rootPath(fd, fsRoot, rootID);
	auto rootFD = open(root.toStringz, O_RDONLY);
	errnoEnforce(rootFD >= 0, "open " ~ root);
	scope(exit) close(rootFD);

	string[] paths;
	inoPaths(rootFD, inode, (char[] fn) {
		paths ~= buildPath(root, cast(string)fn);
	});
	sort(paths);
	return paths;
}

string extentTypeName(u8 type)
{
	final switch (type)
	{
		case BTRFS_FILE_EXTENT_INLINE:
			return "inline";
		case BTRFS_FILE_EXTENT_REG:
			return "regular";
		case BTRFS_FILE_EXTENT_PREALLOC:
			return "prealloc";
	}
}

struct FileExtent
{
	u64 fileOffset;
	u64 length;
	u64 logical;
}

FileExtent getFileExtent(int fd, u64 rootID, u64 inode, u64 fileOffset)
{
	FileExtent result;
	bool found;

	treeSearch!(
		BTRFS_EXTENT_DATA_KEY,
		btrfs_file_extent_item,
	)(
		fd,
		rootID,
		[inode, inode],
		[fileOffset, fileOffset],
		treeSearchAllTransIDs,
		(const ref btrfs_ioctl_search_header header, const ref btrfs_file_extent_item item)
		{
			enforce(!found, "Multiple file extent items at the same offset");
			found = true;

			auto type = btrfs_stack_file_extent_type(&item);
			enforce(type != BTRFS_FILE_EXTENT_INLINE, "Unexpected inline extent reference");

			auto diskBytenr = btrfs_stack_file_extent_disk_bytenr(&item);
			enforce(diskBytenr, "Unexpected hole reference");

			result = FileExtent(
				header.offset,
				btrfs_stack_file_extent_num_bytes(&item),
				diskBytenr + btrfs_stack_file_extent_offset(&item),
			);
		},
	);

	enforce(found, format("Could not find file extent root=%d inode=%d file_off=%d",
		rootID, inode, fileOffset));
	return result;
}

void printRefs(int fd, string fsRoot, u64 diskBytenr, u64 logical, u64 length)
{
	struct Ref
	{
		u64 rootID;
		u64 inode;
		u64 offset;
		u64 overlapLength;
	}

	Ref[] refs;
	// Query the whole backing data extent, then filter by range overlap.
	// A normal LOGICAL_INO point query would only find refs containing the
	// first byte of this file extent, missing refs that overlap later bytes.
	logicalIno(
		fd,
		diskBytenr,
		(u64 inode, u64 offset, u64 rootID)
		{
			auto extent = getFileExtent(fd, rootID, inode, offset);

			auto start = max(logical, extent.logical);
			auto end = min(logical + length, extent.logical + extent.length);
			if (start < end)
				refs ~= Ref(
					rootID,
					inode,
					extent.fileOffset + start - extent.logical,
					end - start,
				);
		},
		true,
	);

	sort!((a, b) =>
		a.rootID != b.rootID ? a.rootID < b.rootID :
		a.inode != b.inode ? a.inode < b.inode :
		a.offset < b.offset
	)(refs);

	foreach (ref_; refs)
	{
		auto paths = pathsForInode(fd, fsRoot, ref_.rootID, ref_.inode);
		if (paths.empty)
			writefln("  ref root=%d inode=%d file_off=%d overlap_len=%d path=<unresolved>",
				ref_.rootID, ref_.inode, ref_.offset, ref_.overlapLength);
		else
			foreach (path; paths)
				writefln("  ref root=%d inode=%d file_off=%d overlap_len=%d path=%s",
					ref_.rootID, ref_.inode, ref_.offset, ref_.overlapLength, path);
	}
}

void btrfsExtentRefs(string filePath, string fsRoot)
{
	filePath = filePath.absolutePath.buildNormalizedPath;
	if (!fsRoot)
		fsRoot = getPathMountInfo(filePath).file;
	enforce(fsRoot.length, "Could not determine filesystem mount point");
	fsRoot = fsRoot.absolutePath.buildNormalizedPath;

	auto fileFD = open(filePath.toStringz, O_RDONLY);
	errnoEnforce(fileFD >= 0, "open " ~ filePath);
	scope(exit) close(fileFD);

	stat_t st;
	errnoEnforce(fstat(fileFD, &st) == 0, "fstat " ~ filePath);
	enforce(S_ISREG(st.st_mode), filePath ~ " is not a regular file");
	enforce(fileFD.isBTRFS, filePath ~ " is not on a btrfs filesystem");

	auto fsFD = open(fsRoot.toStringz, O_RDONLY);
	errnoEnforce(fsFD >= 0, "open " ~ fsRoot);
	scope(exit) close(fsFD);
	enforce(fsFD.isBTRFS, fsRoot ~ " is not on a btrfs filesystem");
	enforce(fsFD.getSubvolumeID == BTRFS_FS_TREE_OBJECTID,
		fsRoot ~ " is not the btrfs top-level subvolume; mount subvol=/ and pass it with --fs-root");

	auto fileRootID = fileFD.getSubvolumeID;
	auto inode = cast(u64)st.st_ino;

	bool sawExtent;
	treeSearch!(
		BTRFS_EXTENT_DATA_KEY,
		btrfs_file_extent_item,
	)(
		fsFD,
		fileRootID,
		[inode, inode],
		treeSearchAllOffsets,
		treeSearchAllTransIDs,
		(const ref btrfs_ioctl_search_header header, const ref btrfs_file_extent_item item)
		{
			sawExtent = true;

			auto type = btrfs_stack_file_extent_type(&item);
			auto fileOffset = header.offset;
			auto length = type == BTRFS_FILE_EXTENT_INLINE
				? header.len - BTRFS_FILE_EXTENT_INLINE_DATA_START
				: btrfs_stack_file_extent_num_bytes(&item);
			auto diskBytenr = type == BTRFS_FILE_EXTENT_INLINE ? 0 : btrfs_stack_file_extent_disk_bytenr(&item);
			auto diskLength = type == BTRFS_FILE_EXTENT_INLINE ? 0 : le64_to_cpu(item.disk_num_bytes);
			auto extentOffset = type == BTRFS_FILE_EXTENT_INLINE ? 0 : btrfs_stack_file_extent_offset(&item);
			auto logical = diskBytenr ? diskBytenr + extentOffset : 0;

			writefln("extent file_off=%d len=%d type=%s disk_bytenr=%d disk_len=%d extent_off=%d logical=%d",
				fileOffset, length, extentTypeName(type), diskBytenr, diskLength, extentOffset, logical);

			if (diskBytenr)
				printRefs(fsFD, fsRoot, diskBytenr, logical, length);
		},
	);

	enforce(sawExtent, "No file extents found");
}

void printUsage()
{
	writeln("Usage: btrfs-extent-refs [--fs-root PATH] FILE");
	writeln();
	writeln("Options:");
	writeln("  --fs-root PATH  Path to the btrfs top-level subvolume for path resolution");
	writeln("  -h, --help      Show this help");
}

int main(string[] args)
{
	string fsRoot;
	bool help;

	try
	{
		getopt(
			args,
			"fs-root", "Path to the btrfs top-level subvolume for path resolution", &fsRoot,
			"help|h", "Show this help", &help,
		);

		if (help || args.length != 2)
		{
			printUsage();
			return help ? 0 : 2;
		}

		btrfsExtentRefs(args[1], fsRoot);
		return 0;
	}
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}
}
