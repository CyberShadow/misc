/**
   Helper module used by the drun* family of programs.
*/

module drunner;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.exception;
import std.string;
//import ae.sys.cmd;

extern(C) __gshared bool rt_cmdline_enabled = false;

int drun(string builder, string[] args)
{
/*
@echo off
if exist "%~f1.exe" del "%~f1.exe"
call dbuild "%~f1"
if exist "%~f1.exe" start "%~f1" /B /WAIT "%~f1.exe"
*/
	args = args[1..$]; // discard self

	string[] buildOptions;
	while (args.length && args[0].startsWith('-'))
	{
		buildOptions ~= args[0];
		args = args[1..$];
	}

	enforce(args.length > 0, "No file");
	auto source = setExtension(args[0], "d");
	auto exe = stripExtension(args[0]);
	//if (exists(exe))
	//	remove(exe);
	//auto spawnProcess(string[] args) { std.stdio.stderr.writeln(args); return std.process.spawnProcess(args); }
	auto result = spawnProcess([builder] ~ buildOptions ~ [source]).wait();
	if (result || !exists(exe) || getSize(exe)==0 || (cast(ubyte[])read(exe))[0]==0)
		return 1;
	version (Windows)
		return spawnProcess([exe.absolutePath] ~ args[1..$]).wait();
	else
	{
		execv(exe, [exe] ~ args[1..$]);
		assert(false);
	}
}
