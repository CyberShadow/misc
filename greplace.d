#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
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
import std.exception;
import std.file;
import std.path;
import std.range;
import std.stdio;
import std.string;
import std.uni;
import std.utf;

import ae.sys.file : listDir;
import ae.utils.array;
import ae.utils.main;
import ae.utils.funopt;
import ae.utils.meta : I;
import ae.utils.text.ascii;

void greplace(
	Switch!("Perform replacement even if it is not reversible", 'f') force,
	Switch!("Copy instead of renaming files", 'c') copy,
	Switch!("Do not actually make any changes", 'n') dryRun,
	Switch!("Search and replace in UTF-16") wide,
	Switch!("Only search and replace in file names and paths") noContent,
	Switch!("Only search and replace in file content") noFilenames,
	Switch!("Recurse in symlinked directories") followSymlinks,
	Switch!("Swap FROM and TO", 'r') reverse,
	Switch!("Case-insensitive, preserve case when replacing", 'i') caseInsensitive,
	Parameter!(string, "String to search", "FROM") firstFrom,
	Parameter!(string, "String to replace with", "TO") firstTo,
	Option!(string[], "Additional FROM", "STR", 'F', "from") extraFrom,
	Option!(string[], "Additional TO", "STR", 'T', "to") extraTo,
	Parameter!(string[], "Paths (files or directories) to search in (default is current directory)") targets = null,
)
{
	if (!targets.length)
		targets = [""];

	string[2][] pairs = [[firstFrom, firstTo]];
	if (extraFrom.length && !extraTo.length)
	{
		// Broadcast all "from" to single "to". Implicitly requires --force.
		enforce(force, "Multiple-FROM to single-TO replacement can not be reversed, and requires --force");
		pairs ~= extraFrom.map!(from => [from, firstTo].staticArray).array;
	}
	else
	if (extraFrom.length == extraTo.length)
		pairs ~= zip(extraFrom, extraTo).map!(pair => [pair.expand].staticArray).array;
	else
		throw new Exception("Mismatching number of from/to pairs");

	auto reversePairs = pairs.dup;
	foreach (ref pair; reversePairs)
		swap(pair[0], pair[1]);
	reversePairs.reverse();

	if (reverse)
		swap(pairs, reversePairs);

	alias Bytes = immutable(ubyte)[];

	Bytes replace(Bytes haystack, const string[2][] pairs, bool inFileContents)
	{
		if (!caseInsensitive)
		{
			foreach (pair; pairs)
				haystack = std.array.replace(
					haystack,
					pair[0].asBytes,
					pair[1].asBytes,
				);

			if (inFileContents && wide)
				foreach (pair; pairs)
					haystack = std.array.replace(
						haystack,
						std.conv.to!wstring(pair[0]).asBytes,
						std.conv.to!wstring(pair[1]).asBytes,
					);
		}
		else
		{
			foreach (pair; pairs)
				haystack = caseInsensitiveReplace(
					haystack.as!string,
					pair[0],
					pair[1],
				).asBytes;

			if (inFileContents && wide)
				foreach (pair; pairs)
				{
					// Even offsets
					haystack = caseInsensitiveReplace(
						haystack[0 .. $ / 2 * 2].as!wstring,
						pair[0],
						pair[1],
					).asBytes ~ haystack[$ / 2 * 2 .. $];
					// Odd offsets
					if (haystack.length)
					haystack = haystack[0 .. 1] ~ caseInsensitiveReplace(
						haystack[1 .. 1 + ($ - 1) / 2 * 2].as!wstring,
						pair[0],
						pair[1],
					).asBytes ~ haystack[1 + ($ - 1) / 2 * 2 .. $];
				}
		}

		return haystack;
	}

	// Check that the replacement is reversible (unless --force is specified).
	if (!force)
		foreach (target; targets)
			target.listDir!((entry) {
				Bytes s;
				if (!noFilenames && !followSymlinks && entry.isSymlink)
					s = cast(Bytes)readLink(entry.fullName);
				else
				if (!noContent && (followSymlinks ? entry.isFile : entry.entryIsFile))
					s = cast(Bytes)std.file.read(entry.fullName);

				if (s)
				{
					if (s.I!replace(pairs, true).I!replace(reversePairs, true) != s)
						throw new Exception(
							pairs.length == 1
							? "File " ~ entry.fullName ~ " already contains " ~ pairs[0][1]
							: "Replacement in file " ~ entry.fullName ~ " is not reversible"
						);
				}

				if (!noFilenames && entry.fullName.asBytes.I!replace(pairs, false).I!replace(reversePairs, false) != entry.fullName)
					throw new Exception(
						pairs.length == 1
						? "File name " ~ entry.fullName ~ " already contains " ~ pairs[0][1]
						: "Replacement in file name " ~ entry.fullName ~ " is not reversible"
					);

				if (followSymlinks ? entry.isDir : entry.entryIsDir)
					entry.recurse();
			}, Yes.includeRoot);

	// Replacing in paths occurs as follows:
	// 1. Apply transformation to directory path
	// 2. Recurse
	//    - In order to perform the replacement exactly once for all paths,
	//      remember what the original path was and apply the transformation to it,
	//      not the current path.
	void scan(string root, string originalName, string currentName)
	{
		auto originalPath = root.buildPath(originalName);
		auto currentPath = root.buildPath(currentName);

		// This listDir is non-recursive and only fetches the directory entry's properties.
		currentPath.listDir!((entry) {
			assert(entry.fullName == currentPath || (entry.fullName == "." && currentPath == ""),
				entry.fullName ~ " != " ~ currentPath);

			Bytes s;
			bool replaceNeeded;

			if ((!noFilenames || copy) && !followSymlinks && entry.isSymlink)
			{
				s = cast(Bytes)readLink(currentPath);
				replaceNeeded = !noFilenames;
			}
			else
			if ((!noContent || copy) && (followSymlinks ? entry.isFile : entry.entryIsFile))
			{
				s = cast(Bytes)std.file.read(currentPath);
				replaceNeeded = !noContent;
			}

			bool writeNeeded;

			string targetName = currentName;
			string targetPath = currentPath;

			if (!noFilenames)
			{
				targetName = originalName.asBytes.I!replace(pairs, false).as!string;
				targetPath = root.buildPath(targetName);

				if (targetName != originalName)
					writeln(originalPath, " -> ", targetPath);

				if (targetName != currentName)
				{
					if (!exists(targetPath.dirName))
					{
						if (!dryRun)
							mkdirRecurse(targetPath.dirName);
					}

					if (copy)
						writeNeeded = true;
					else
					{
						if (!dryRun)
						{
							std.file.rename(currentPath, targetPath);

							// TODO: empty folders

							auto segments = currentName.pathSplitter().array()[0 .. $-1];
							foreach_reverse (i; 0 .. segments.length)
							{
								auto dir = buildPath([root] ~ segments[0 .. i+1]);
								if (dir.dirEntries(SpanMode.shallow).empty)
									rmdir(dir);
							}
						}

						if (dryRun)
						{
							// TODO: Pretend that the files were renamed
						}
						else
						{
							// Track that we have renamed this file.
							currentName = targetName;
							currentPath = targetPath;
						}
					}
				}
			}

			if (replaceNeeded)
			{
				auto orig = s;
				s = s.I!replace(pairs, true);

				if (s !is orig && s != orig)
				{
					writeln(currentPath);
					writeNeeded = true;
				}
			}

			if (writeNeeded && !dryRun)
			{
				if (!followSymlinks && entry.isSymlink)
				{
					if (currentPath == targetPath)
						remove(targetPath);
					symlink(cast(string)s, targetPath);
				}
				else
				if (followSymlinks ? entry.isFile : entry.entryIsFile)
					std.file.write(targetPath, s);
				else
				if (followSymlinks ? entry.isDir : entry.entryIsDir)
				{
					assert(copy);
					mkdir(targetPath);
				}
				else
					assert(false);
			}

			if (followSymlinks ? entry.isDir : entry.entryIsDir)
			{
				// Avoid modifying the directory we're iterating by eagerly enumerating its entries.
				string[] entries;
				currentPath.listDir!((entry) {
					entries ~= entry.baseName;
				}, No.includeRoot);

				foreach (entryName; entries)
					scan(
						root,
						originalName.buildPath(entryName),
						currentName.buildPath(entryName),
					);
			}
		}, Yes.includeRoot);
	}

	enum keepRoot = false;
	foreach (target; targets)
		if (keepRoot)
			scan(target, null, null);
		else
			scan(null, target, target);
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

	if (from.asBytes.all!(c => c < 0x80))
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

alias mainFunc = funopt!greplace;

// Basic test
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo");
	mainFunc(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/test.txt") == "bar");
}

// Test renaming parent directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/x.txt", "foo");
	mainFunc(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/x.txt") == "bar");
}

// Rename with prefix
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdirRecurse(dir ~ "/foo/foo");
	std.file.write(dir ~ "/foo/foo/foo.txt", "foo");
	mainFunc(["greplace", "foo", "foobar", dir]);
	assert(readText(dir ~ "/foobar/foobar/foobar.txt") == "foobar");
}

// Dry-run
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdirRecurse(dir ~ "/foo/foo");
	std.file.write(dir ~ "/foo/foo/foo.txt", "foo");
	mainFunc(["greplace", "-n", "foo", "foobar", dir]);
	assert(readText(dir ~ "/foo/foo/foo.txt") == "foo");
}

// Copy mode
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdirRecurse(dir ~ "/foo/foo");
	std.file.write(dir ~ "/foo/foo/foo.txt", "foo");
	mainFunc(["greplace", "-c", "foo", "bar", dir]);
	assert(readText(dir ~ "/foo/foo/foo.txt") == "foo");
	assert(readText(dir ~ "/bar/bar/bar.txt") == "bar");
}

// Copy mode - filenames only
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdirRecurse(dir ~ "/foo/foo");
	std.file.write(dir ~ "/foo/foo/foo.txt", "foo");
	mainFunc(["greplace", "-c", "--no-content", "foo", "bar", dir]);
	assert(readText(dir ~ "/foo/foo/foo.txt") == "foo");
	assert(readText(dir ~ "/bar/bar/bar.txt") == "foo");
}

// Replace in current directory
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo");
	{
		auto oldPwd = getcwd(); scope(exit) chdir(oldPwd);
		chdir(dir);
		mainFunc(["greplace", "foo", "bar"]);
	}
	assert(readText(dir ~ "/test.txt") == "bar");
}

// Renamed empty directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/foo.txt", "foo");
	mainFunc(["greplace", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/bar.txt") == "bar");
}

// Renaming specified directories
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	std.file.write(dir ~ "/foo/foo.txt", "foo");
	mainFunc(["greplace", "foo", "bar", dir ~ "/foo"]);
	assert(readText(dir ~ "/bar/bar.txt") == "bar");
}

// Renaming with -f (skips early stat)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	mkdir(dir ~ "/foo/baz");
	std.file.write(dir ~ "/foo/baz/foo.txt", "foo");
	mainFunc(["greplace", "-f", "foo", "bar", dir]);
	assert(readText(dir ~ "/bar/baz/bar.txt") == "bar");
}

// Replacing in symlink targets
version (Posix)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/foo");
	symlink("foo", dir ~ "/baz");
	mainFunc(["greplace", "foo", "bar", dir]);
	assert(readLink(dir ~ "/baz") == "bar");
}

// Replacing in broken symlink targets
version (Posix)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	symlink("foo", dir ~ "/baz");
	mainFunc(["greplace", "foo", "bar", dir ~ "/baz"]);
	assert(readLink(dir ~ "/baz") == "bar");
}

// Following symlinks
version (Posix)
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	mkdir(dir ~ "/target1"); std.file.write(dir ~ "/target1/file.txt", "foo");
	std.file.write(dir ~ "/target2.txt", "foo");
	mkdir(dir ~ "/src");
	symlink("../target1", dir ~ "/src/link1");
	symlink("../target2.txt", dir ~ "/src/link2.txt");
	mainFunc(["greplace", "--follow-symlinks", "foo", "bar", dir ~ "/src"]);
	assert(readText(dir ~ "/target1/file.txt") == "bar");
	assert(readText(dir ~ "/target2.txt") == "bar");
}

// Case-insensitive
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo Foo FOO fOO");
	mainFunc(["greplace", "-i", "foo", "quux", dir]);
	assert(readText(dir ~ "/test.txt") == "quux Quux QUUX qUUX");
}

// Case-insensitive - camel case
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "myIdentifier MyIdentifier MYIDENTIFIER myidentifier");
	mainFunc(["greplace", "-i", "myIdentifier", "myNewIdentifier", dir]);
	assert(readText(dir ~ "/test.txt") == "myNewIdentifier MyNewIdentifier MYNEWIDENTIFIER mynewidentifier");
}

// Case-insensitive - Unicode
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "яблоко Яблоко ЯБЛОКО яБЛОКО");
	mainFunc(["greplace", "-i", "яблоко", "груша", dir]);
	assert(readText(dir ~ "/test.txt") == "груша Груша ГРУША гРУША");
}

// Multiple pairs
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foobaz");
	mainFunc(["greplace", "foo", "bar", "-F", "baz", "-T", "quux", dir]);
	assert(readText(dir ~ "/test.txt") == "barquux");
}

// Multiple pairs - chain
unittest
{
	auto dir = deleteme; mkdir(dir); scope(exit) rmdirRecurse(dir);
	std.file.write(dir ~ "/test.txt", "foo");
	mainFunc(["greplace", "foo", "bar", "-F", "bar", "-T", "baz", dir]);
	assert(readText(dir ~ "/test.txt") == "baz");
}

mixin main!mainFunc;

version (unittest_only)
shared static this()
{
	import core.runtime : Runtime, UnitTestResult;
	Runtime.extendedModuleUnitTester = {
		foreach (m; ModuleInfo)
			if (m)
				if (auto fp = m.unitTest)
					fp();
		return UnitTestResult();
	};
}
