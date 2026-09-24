#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
 dflags "-i"  # https://github.com/dlang/dub/issues/2638
 stringImportPaths "."
+/

/// Visualize what a btrfs send stream contains, as a treemap.
module btrfs_send_treemap;

import core.sys.posix.sys.stat : chmod;

import std.array : replace;
import std.conv : octal;
import std.exception : enforce;
import std.file : tempDir, write;
import std.path : buildPath;
import std.process : browse;
import std.stdio : File, toFile, stderr;
import std.string : toStringz;

import ae.sys.file : readFile;
import ae.utils.funopt : funopt, Parameter, Option;
import ae.utils.json : jsonParse, toJson;
import ae.utils.main : main;
import ae.utils.text : randomString;

import btrfs_send_stream;

enum viewerHTML = import("path-treemap-viewer.html");

/// Tree in the format expected by the viewer.
struct TreeNode
{
	ulong size;
	TreeNode[string] children;
}

/// Approximate size of a stream command, besides the file data it carries.
enum commandMetadataSize = 64;

TreeNode toTreeNode(in DeltaTree tree)
{
	TreeNode node;
	node.size = tree.size + tree.commands * commandMetadataSize;
	foreach (name, child; tree.children)
		node.children[name] = toTreeNode(child);
	return node;
}

/// Read the per-path totals from a send stream or a metadata sidecar.
DeltaTree readTree(File f)
{
	ubyte[64 * 1024] buffer;
	auto head = f.rawRead(buffer[0 .. sendStreamMagic.length]);
	if (head == sendStreamMagic[])
	{
		SendStreamParser parser;
		parser.put(head);
		while (true)
		{
			auto chunk = f.rawRead(buffer[]);
			if (chunk.length == 0)
				break;
			parser.put(chunk);
		}
		return parser.finishTree();
	}
	else
	{
		auto metadata = (cast(string)(head ~ readFile(f))).jsonParse!SnapshotMetadata;
		enforce(metadata.formatVersion == SnapshotMetadata.init.formatVersion,
			"Unsupported metadata version");
		return metadata.delta.tree;
	}
}

void btrfs_send_treemap(
	Parameter!(string, "btrfs send stream, or metadata sidecar written by btrfs-snapshot-archive\n(use /dev/stdin to read from stdin)") inFileName,
	Option!(string, "Path to where to save the HTML report\n(open a temporary file in browser by default)") outFileName,
)
{
	auto root = File(inFileName, "rb").readTree.toTreeNode;

	bool doBrowse;
	if (!outFileName)
	{
		outFileName = tempDir.buildPath(randomString ~ ".html");
		write(outFileName, "");
		chmod(outFileName.toStringz, octal!600);
		doBrowse = true;
	}

	viewerHTML
		.replace("%TREEDATA%", root.toJson.toJson)
		.toFile(outFileName);
	stderr.writeln(outFileName, " written");
	if (doBrowse)
		browse(outFileName);
}

mixin main!(funopt!btrfs_send_treemap);
