module linux_config_bisectrepo_gen;

/// Generate the diff between two kernel .config files,
/// in a format consumable by linux-config-bisectrepo-apply.

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.stdio;
import std.string;

import ae.utils.main;
import ae.utils.funopt;

import linux_config_common;

enum FN = ".config";

void linuxConfigEditPathGen(string oldFile, string newFile)
{
	bool[string] both;
	string[string] aVals, bVals;

	loadConfig(oldFile, aVals, both);
	loadConfig(newFile, bVals, both);

	foreach (key; both.keys.sort())
		if (key in aVals && key !in bVals)
			writeln("-", key);
		else
		if (key !in aVals && key in bVals)
			writeln("+", key, "=", bVals[key]);
		else
		if (aVals[key] != bVals[key])
			writeln("=", key, "=", bVals[key]);
}

mixin main!(funopt!linuxConfigEditPathGen);
