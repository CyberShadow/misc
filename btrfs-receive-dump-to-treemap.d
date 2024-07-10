#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
 stringImportPaths "."
+/

module btrfs_receive_dump_to_treemap;

import core.sys.posix.sys.stat : chmod;

import std.algorithm.iteration : splitter;
import std.algorithm.searching : findSplit;
import std.array : replace;
import std.conv : to, octal;
import std.file : tempDir, write;
import std.path : buildPath;
import std.process : browse;
import std.stdio : File, toFile, stderr;
import std.string : toStringz;

import ae.utils.funopt : funopt, Parameter, Option;
import ae.utils.json : toJson;
import ae.utils.main : main;
import ae.utils.text : randomString;

enum viewerHTML = import("path-treemap-viewer.html");

void btrfs_receive_dump_to_treemap(
	Parameter!(string, "File containing output of btrfs receive --dump\n(use /dev/stdin to read from stdin)") dumpFileName,
	Option!(string, "Path to where to save the HTML report\n(open a temporary file in browser by default)") outFileName,
)
{
	struct TreeNode
	{
		ulong size;
		TreeNode[string] children;
	}
	TreeNode root;

	enum tokenMetadataSize = 64;
	
	foreach (line; File(dumpFileName, "rb").byLine)
	{
		if (line.length <= 16)
			continue;

		ulong size = tokenMetadataSize;
		{
			auto p = line.findSplit(" len=");
			if (p[1].length)
				size += p[2].findSplit(" ")[0].to!ulong;
		}

		auto path = line[16..$];
		{
			size_t p = 0;
			while (p < path.length)
				if (path[p] == '\\')
					p += 2;
				else
				if (path[p] == ' ')
					break;
				else
					p++;
			path = path[0 .. p];
		}

		auto node = &root;
		foreach (segment; path.splitter("/"))
		{
			node.size += size;
			auto next = segment in node.children;
			if (!next)
			{
				node.children[segment.idup] = TreeNode();
				next = segment in node.children;
			}
			node = next;
		}

		// Leaf
		node.size += size;
	}

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

mixin main!(funopt!btrfs_receive_dump_to_treemap);
