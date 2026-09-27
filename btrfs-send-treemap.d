#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
 dflags "-i"  # https://github.com/dlang/dub/issues/2638
 stringImportPaths "."
+/

/// Visualize what btrfs send streams contain, as a treemap or in ncdu.
module btrfs_send_treemap;

import core.sys.posix.sys.stat : chmod;

import std.algorithm.iteration : map, sum;
import std.algorithm.sorting : sort;
import std.array : replace;
import std.conv : octal;
import std.exception : enforce;
import std.file : tempDir, write;
import std.path : baseName, buildPath;
import std.process : browse;
import std.stdio : File, toFile, stderr, stdout;
import std.string : toStringz;

import ae.sys.file : readFile;
import ae.utils.funopt : funopt, Parameter, Option, Switch;
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

/// Add the totals of `b` to `a`, path by path.
void add(ref DeltaTree a, in DeltaTree b)
{
	a.size += b.size;
	a.commands += b.commands;
	foreach (name, child; b.children)
		a.children.require(name).add(child);
}

/// Write `tree` in ncdu's JSON export format, for browsing with `ncdu -f`.
/// ncdu's "apparent size" is the file data written; its "disk usage"
/// additionally counts the approximate size of the stream commands.
void writeNcdu(File f, string rootName, in DeltaTree tree)
{
	f.writeln(`[1,2,{"progname":"btrfs-send-treemap","progver":"1"},`);
	writeNcduEntry(f, rootName, tree);
	f.writeln("]");
}

private void writeNcduEntry(File f, string name, in DeltaTree tree)
{
	// ncdu entries have their own sizes; DeltaTree's include the children's.
	auto size = tree.size - tree.children.byValue.map!(child => child.size).sum;
	auto commands = tree.commands - tree.children.byValue.map!(child => child.commands).sum;
	auto info = `{"name":` ~ name.toJson ~ `,"asize":` ~ size.toJson ~ `,"dsize":` ~ (size + commands * commandMetadataSize).toJson ~ `}`;
	if (tree.children.length) // directory
	{
		f.write("[", info);
		foreach (childName; tree.children.keys.sort)
		{
			f.write(",\n");
			writeNcduEntry(f, childName, tree.children[childName]);
		}
		f.write("]");
	}
	else
		f.write(info);
}

unittest
{
	DeltaTree a = { size: 10, commands: 3, children: [
		"dir": DeltaTree(10, 2, ["file": DeltaTree(10, 1)]),
	] };
	DeltaTree b = { size: 5, commands: 2, children: [
		"dir": DeltaTree(5, 1),
	] };
	a.add(b);
	assert(a.size == 15 && a.commands == 5);
	assert(a.children["dir"].size == 15 && a.children["dir"].commands == 3);
	assert(a.children["dir"].children["file"].size == 10);

	auto f = File.tmpfile();
	writeNcdu(f, "@x", a);
	f.rewind();
	import std.array : join, array;
	assert(f.byLineCopy.array.join("\n") ==
		`[1,2,{"progname":"btrfs-send-treemap","progver":"1"},` ~ "\n" ~
		`[{"name":"@x","asize":0,"dsize":128},` ~ "\n" ~
		`[{"name":"dir","asize":5,"dsize":133},` ~ "\n" ~
		`{"name":"file","asize":10,"dsize":74}]]]`);
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
	Parameter!(string[], "btrfs send streams, or metadata sidecars written by btrfs-snapshot-archive\n(use /dev/stdin to read from stdin);\nthe totals of multiple inputs are added up") inFileNames,
	Switch!("Write ncdu's JSON export format (for `ncdu -f`), instead of an HTML treemap") ncdu,
	Option!(string, "Path to where to save the output\n(by default, the HTML treemap is opened in a browser,\nand ncdu data is written to standard output)") outFileName,
)
{
	enforce(inFileNames.length, "No input files specified");
	DeltaTree tree;
	foreach (inFileName; inFileNames)
		tree.add(File(inFileName, "rb").readTree);

	if (ncdu)
	{
		auto rootName = inFileNames.length == 1 ? inFileNames[0].baseName : "(total of " ~ inFileNames.length.toJson ~ " deltas)";
		writeNcdu(outFileName ? File(outFileName, "wb") : stdout, rootName, tree);
		return;
	}

	auto root = tree.toTreeNode;

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
