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
	try
	{
		args = args[1..$]; // discard self

		string[] buildOptions;
		string exe;
		while (args.length && args[0].startsWith('-'))
		{
			if (args[0].startsWith("-of"))
				exe = args[0][3..$];
			buildOptions ~= args[0];
			args = args[1..$];
		}

		enforce(args.length > 0, "No file");
		auto source = setExtension(args[0], "d");
		if (!exe)
			exe = stripExtension(args[0]);
		//if (exists(exe))
		//	remove(exe);
		//auto spawnProcess(string[] args) { std.stdio.stderr.writeln(args); return std.process.spawnProcess(args); }
		auto result = spawnProcess([builder] ~ buildOptions ~ [source]).wait();
		if (result)
			return result;
		enforce(exe.exists, "Executable was not created: " ~ exe);
		enforce(getSize(exe) > 0, "Executable has zero size: " ~ exe);
		enforce((cast(ubyte[])read(exe))[0]!=0, "Executable is corrupted: " ~ exe);
		version (Windows)
			return spawnProcess([exe.absolutePath] ~ args[1..$]).wait();
		else
		{
			execv(exe, [exe] ~ args[1..$]);
			assert(false);
		}
	}
	catch (Exception e)
	{
		stderr.writeln("drun: ", e.msg);
		return 1;
	}
}
