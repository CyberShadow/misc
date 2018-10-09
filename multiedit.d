/**
   Edit multiple files as one, by temporarily concatenating them.

   The temporary format is similar to HAR:
   https://github.com/marler8997/har
*/

// import core.stdc.stdio;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.ascii;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.random;
import std.stdio;
import std.string;
import std.utf;

import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text;

void multiedit(string[] files, Option!string prefix = "---")
{
	auto delimiter = ('\n' ~ prefix ~ ' ').representation;

	ubyte[] data;
	foreach (fn; files)
	{
		enforce(!fn.contains('\n'), "Can't handle newlines in file names");
		data ~= delimiter ~ fn.representation ~ '\n';
		auto fileBytes = cast(ubyte[])read(fn);
		enforce(!fileBytes.contains(delimiter), "Prefix %s found in file %s".format(prefix, fn));
		if (fileBytes.canFind!(b => b == 0x00))
			stderr.writefln("multiedit: Warning: File %s looks binary", fn);
		data ~= fileBytes;
	}

	if (data.length)
		data = data[1..$]; // remove leading newline

	auto id = letters.byCodeUnit.randomSample(20).to!string;
	auto exts = files.map!extension.array.sort.uniq.array;
	auto tempFile = buildPath(tempDir, "multiedit_" ~ id ~ (exts.length == 1 ? exts[0] : ""));
	version(none)
	{
		auto fd = open(tempFile.toStringz, O_CREAT | O_EXCL, octal!600);
		errnoEnforce(fd >= 0, "open() failed");
		scope(exit) remove(tempFile);
		scope(exit) close(fd);
		File f;
		f.fdopen(fd, "wb");
		f.rawWrite(data);
		f.close();
	}
	else
	{
		enforce(!tempFile.exists, "%s already exists".format(tempFile));
		std.file.write(tempFile, data);
		scope(exit) remove(tempFile);
	}

	auto status = spawnProcess([environment.get("EDITOR", "editor"), tempFile]).wait();
	enforce(status == 0, "Editor exited with status %s".format(status));

	data = cast(ubyte[])read(tempFile);
	if (!data.length)
	{
		stderr.writeln("multiedit: Edited file empty, exiting");
		return;
	}

	enforce(data.skipOver(prefix ~ ' '), "Archive corrupt (expected delimiter)");

	while (data.length)
	{
		auto fileName = cast(string)data.skipUntil('\n').enforce("Archive corrupt (unterminated header)");
		auto fileData = data.skipUntil(delimiter, true);
		std.file.write(fileName, fileData);
	}
}

mixin main!(funopt!multiedit);
