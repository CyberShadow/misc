#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/**
   Replace a raw string in the given files and file names.

   By default, ensures that the operation is undoable, i.e. aborts if
   the new string is already found in any of the files.
*/

module greplace;

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.file;
import std.getopt;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.uni;
import std.utf;

import ae.utils.array;
import ae.utils.main;
import ae.utils.funopt;
import ae.utils.meta : I;
import ae.utils.text.ascii;

void greplace(
	Switch!("Perform replacement even if it is not reversible", 'f') force,
	Switch!("Do not actually make any changes", 'n') dryRun,
	Switch!("Search and replace in UTF-16") wide,
	Switch!("Only search and replace in file names and paths") noContent,
	Switch!("Only search and replace in file content") noFilenames,
	Switch!("Recurse in symlinked directories") followSymlinks,
	Switch!("Swap FROM-STR and TO-STR", 'r') reverse,
	Switch!("Case-insensitive, preserve case when replacing", 'i') caseInsensitive,
	Parameter!(string, "String to search") from,
	Parameter!(string, "String to replace with") to,
	Parameter!(string[], "Paths (files or directories) to search in (default is current directory)") targets = null,
)
{
	if (!targets.length)
		targets = [""];

	if (reverse)
		swap(from.value, to.value);

	wstring fromw, tow;
	if (wide)
	{
		fromw = std.conv.to!wstring(from);
		tow   = std.conv.to!wstring(to);
	}

	alias Bytes = immutable(ubyte)[];

	Bytes replace(Bytes haystack, string from, string to, bool inFileContents)
	{
		if (!caseInsensitive)
		{
			haystack = std.array.replace(
				haystack,
				from.bytes,
				to.bytes,
			);

			if (inFileContents && wide)
			{
				haystack = std.array.replace(
					haystack,
					fromw.bytes,
					tow.bytes,
				);
			}
		}
		else
		{
			haystack = caseInsensitiveReplace(
				haystack.fromBytes!string,
				from,
				to
			).bytes;

			if (inFileContents && wide)
			{
				// Even offsets
				haystack = caseInsensitiveReplace(
					haystack[0 .. $ / 2 * 2].fromBytes!wstring,
					from,
					to
				).bytes ~ haystack[$ / 2 * 2 .. $];
				// Odd offsets
				if (haystack.length)
				haystack = haystack[0 .. 1] ~ caseInsensitiveReplace(
					haystack[1 .. 1 + ($ - 1) / 2 * 2].fromBytes!wstring,
					from,
					to
				).bytes ~ haystack[1 + ($ - 1) / 2 * 2 .. $];
			}
		}

		return haystack;
	}

	auto targetFiles = targets.map!(target =>
		target.empty || (!target.isSymlink && target.isDir)
		? dirEntries(target, SpanMode.breadth, followSymlinks).array
		: [DirEntry(target)]
	).array;

	if (!force)
	{
		foreach (targetIndex, target; targets)
			foreach (ref file; targetFiles[targetIndex])
			{
				Bytes s;
				if (!noFilenames && file.isSymlink())
					s = cast(Bytes)readLink(file.name);
				else
				if (!noContent && !file.isSymlink() && file.isFile())
					s = cast(Bytes)std.file.read(file.name);

				if (s)
				{
					if (s.I!replace(from, to, true).I!replace(to, from, true) != s)
						throw new Exception("File " ~ file.name ~ " already contains " ~ to);
				}

				if (!noFilenames && file.name.bytes.I!replace(from, to, false).I!replace(to, from, false) != file.name)
					throw new Exception("File name " ~ file.name ~ " already contains " ~ to);
			}
	}

	// Ensure stat is done on these DirEntry instances before any renames are done
	foreach (targetIndex, target; targets)
		foreach (ref file; targetFiles[targetIndex])
			file.isSymlink(), file.isFile();

	foreach (targetIndex, target; targets)
		foreach (ref file; targetFiles[targetIndex])
		{
			// Apply renames of parent directories
			string fileName;
			foreach (segment; file.name.pathSplitter)
			{
				if (!noFilenames && fileName.length > target.length)
					fileName = fileName.bytes.I!replace(from, to, false).fromBytes!string;
				fileName = fileName.buildPath(segment);
			}

			Bytes s;
			if (!noFilenames && file.isSymlink())
				s = cast(Bytes)readLink(fileName);
			else
			if (!noContent && !file.isSymlink() && file.isFile())
				s = cast(Bytes)std.file.read(fileName);

			if (s)
			{
				auto orig = s;
				s = s.I!replace(from, to, true);

				if (s !is orig && s != orig)
				{
					writeln(file.name);

					if (!dryRun)
					{
						if (file.isSymlink())
						{
							remove(fileName);
							symlink(cast(string)s, fileName);
						}
						else
						if (file.isFile())
							std.file.write(fileName, s);
						else
							assert(false);
					}
				}
			}

			if (!noFilenames)
			{
				string newName = fileName.bytes.I!replace(from, to, false).fromBytes!string;
				if (newName != fileName)
				{
					writeln(fileName, " -> ", newName);

					if (!dryRun)
					{
						if (!exists(dirName(newName)))
							mkdirRecurse(dirName(newName));
						std.file.rename(fileName, newName);

						// TODO: empty folders

						auto segments = array(pathSplitter(fileName))[0..$-1];
						foreach_reverse (i; 0..segments.length)
						{
							auto dir = buildPath(segments[0..i+1]);
							if (array(map!`a.name`(dirEntries(dir, SpanMode.shallow))).length==0)
								rmdir(dir);
						}
					}
				}
			}
		}
}

S convertCase(E, S)(E example, S str)
{
	if (example.empty || str.empty)
		return str;

	auto convertPart(E, S)(E example, S str)
	{
		bool haveLower, haveUpper;
		foreach (dchar c; example)
		{
			auto l = std.uni.toLower(c);
			auto u = std.uni.toUpper(c);
			if (l != u && c == l)
				haveLower = true;
			if (l != u && c == u)
				haveUpper = true;
		}
		if (haveLower == haveUpper)
			return str.to!(ElementEncodingType!S[]);
		if (haveLower)
			return std.uni.toLower(str);
		if (haveUpper)
			return std.uni.toUpper(str);
		assert(false);
	}

	return chain(
		convertPart(example.takeOne, str.takeOne),
		convertPart(example.dropOne, str.dropOne),
	).to!S;
}

H caseInsensitiveReplace(H)(H haystack, string from, string to)
{
	// Performs search-and-replace with supplied predicate doing the matching.
	// `pred.check` returns number of elements to remove if matched, -1 if not matched.
	H doReplace(Pred)(Pred pred)
	{
		auto result = appender!H();
		size_t start = 0;
		size_t i = 0;
		while (i < haystack.length)
		{
			auto matched = pred.check(haystack[i .. $]);
			if (matched != -1)
			{
				result.put(haystack[start .. i]);
				result.put(convertCase(haystack[i .. i + matched], to));
				i = start = i + matched;
			}
			else
				i++;
		}
		result.put(haystack[start .. $]);
		return result.data;
	}

	if (from.bytes.all!(c => c < 0x80))
	{
		// ASCII case-insensitive search
		struct Pred
		{
			string prefix;
			size_t check(H haystack)
			{
				if (haystack.byCodeUnit.map!(c => c < 0x80 ? std.ascii.toLower(c) : cast(char)0xFF).startsWith(prefix))
					return prefix.length;
				else
					return -1;
			}
		}
		return doReplace(Pred(from.byCodeUnit.map!(std.ascii.toLower).array));
	}
	else
	{
		// Unicode case-insensitive search
		struct Pred
		{
			dchar[] prefix;
			size_t check(H haystack)
			{
				auto needle = prefix;
				auto origLength = haystack.length;
				while (!needle.empty)
				{
					if (haystack.empty)
						return -1;
					auto haystackChar = haystack.decodeFront!(Yes.useReplacementDchar)();
					if (haystackChar == replacementDchar)
						return -1;
					auto needleChar = needle.front;
					needle.popFront();
					if (std.uni.toLower(haystackChar) != needleChar)
						return -1;
				}
				return origLength - haystack.length;
			}
		}
		return doReplace(Pred(from.map!(std.uni.toLower).array));
	}
}

version (Windows)
{
	bool isSymlink(string /*path*/) { return false; }
	string readLink(string /*path*/) { assert(false); }
	void symlink(string /*from*/, string /*to*/) { assert(false); }
}

// Basic test
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo");
	main(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/test.txt") == "bar");
}

// Test renaming parent directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/x.txt", "foo");
	main(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/x.txt") == "bar");
}

// Renamed empty directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/foo.txt", "foo");
	main(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/bar.txt") == "bar");
}

// Renaming specified directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/foo.txt", "foo");
	main(["greplace", "foo", "bar", dir ~ "/foo"]);
	assert(readText(dir ~ "/bar/bar.txt") == "bar");
}

// Renaming with -f (skips early stat)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	mkdir(dir ~ "/foo/baz");
	std.file.write(dir ~ "/foo/baz/foo.txt", "foo");
	main(["greplace", "-f", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/baz/bar.txt") == "bar");
}

// Replacing in symlink targets
version (Posix)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	symlink("foo", dir ~ "/baz");
	main(["greplace", "foo", "bar", dir]);
	assert(readLink(dir ~ "/baz") == "bar");
}

// Replacing in broken symlink targets
version (Posix)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	symlink("foo", dir ~ "/baz");
	main(["greplace", "foo", "bar", dir ~ "/baz"]);
	assert(readLink(dir ~ "/baz") == "bar");
}

// Case-insensitive
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo Foo FOO fOO");
	main(["greplace", "-i", "foo", "quux", dir]);
	assert(readText(dir ~ "/test.txt") == "quux Quux QUUX qUUX");
}

// Case-insensitive - camel case
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "myIdentifier MyIdentifier MYIDENTIFIER myidentifier");
	main(["greplace", "-i", "myIdentifier", "myNewIdentifier", dir]);
	assert(readText(dir ~ "/test.txt") == "myNewIdentifier MyNewIdentifier MYNEWIDENTIFIER mynewidentifier");
}

// Case-insensitive - Unicode
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "яблоко Яблоко ЯБЛОКО яБЛОКО");
	main(["greplace", "-i", "яблоко", "груша", dir]);
	assert(readText(dir ~ "/test.txt") == "груша Груша ГРУША гРУША");
}

mixin main!(funopt!greplace);
