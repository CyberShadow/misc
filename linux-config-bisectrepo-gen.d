/**
   Generate the edit path from one kernel .config to another, as a
   git repository.

   This allows bisecting the resulting repository to discover which
   configuration entry is responsible for some certain reproducible
   behaviour.
*/

module linux_config_bisectrepo_gen;

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.utils.main;
import ae.utils.funopt;

import linux_config_common;

enum FN = ".config";

void linuxConfigBisectRepoGen(string oldFile, string newFile, string dir)
{
	enforce(!dir.exists, dir ~ " already exists!");

	bool[string] both;
	string[string] aVals, bVals;

	loadConfig(oldFile, aVals, both);
	loadConfig(newFile, bVals, both);

	mkdir(dir);
	enforce(spawnProcess(["git", "init", "."], null, Config.none, dir).wait() == 0, "git init failed");

	string[] diff, all;
	all = both.keys;
	all.sort();
	foreach (key; all)
		if ((key !in aVals) != (key !in bVals) || aVals[key] != bVals[key])
			diff ~= key;

	foreach (n; 0..diff.length+1)
	{
		auto f = File(dir.buildPath(FN), "wb");
		foreach (key; all)
		{
			auto vals = n == diff.length || key < diff[n] ? bVals : aVals;
			if (auto pValue = key in vals)
				f.writeln(key ~ '=' ~ *pValue);
		}
		f.close();
		enforce(spawnProcess(["git", "add", FN], null, Config.none, dir).wait() == 0, "git add failed");
		enforce(spawnProcess(["git", "commit", "-m", n ? diff[n-1] : "Initial commit"], null, Config.none, dir).wait() == 0, "git commit failed");
		if (!n) enforce(spawnProcess(["git", "tag", "base"], null, Config.none, dir).wait() == 0, "git tag failed");
	}

	enforce(spawnProcess(["git", "repack", "-ad"], null, Config.none, dir).wait() == 0, "git repack failed");
}

mixin main!(funopt!linuxConfigBisectRepoGen);
