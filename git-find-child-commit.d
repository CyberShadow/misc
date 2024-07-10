#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Finds all commits which reference the given commit as a parent.
   Searches all commit objects, whether they're reachable or not.
*/

module git_find_child_commit;

private:

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.digest.sha;
import std.parallelism;
import std.process;
import std.stdio;
import std.string;
import std.typecons;

import ae.sys.git;
import ae.utils.array;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta;
import ae.utils.text;

int git_find_child_commit(
	string parentCommitID,
)
{
	auto parsedParentCommitID = Git.CommitID(parentCommitID);

	auto repo = Git(".");

	auto p = repo.pipe(["cat-file", "--batch-check", "--batch-all-objects"]);
	bool found;

	auto commits = p.stdout
		.byLine
		.map!((line) {
			auto oid = Git.OID(line.skipUntil(' '));
			auto type = line.skipUntil(' ', true);
			return tuple(oid, type);
		})
		.filter!(p => p[1] == "commit")
		.map!(p => p[0])
	;
	auto monitor = new Object;

	foreach (oid; commits.parallel(64))
	{
		static Git.ObjectReader reader;
		if (reader is Git.ObjectReader.init)
			reader = repo.createObjectReader();

		static uint counter;
		try
		{
			if (counter++ % 64 == 0)
				synchronized(monitor) { stderr.write(oid.toString()[0 .. 4], "...\r"); stderr.flush(); }
			auto commit = reader.read(oid).parseCommit();
			foreach (parent; commit.parents)
				if (parent == parsedParentCommitID)
				{
					synchronized(monitor) writeln(oid.toString());
					found = true;
				}
		}
		catch (Exception e)
			synchronized(monitor) stderr.writeln("Error with " ~ oid.toString() ~ ": " ~ e.msg);
	}
	p.pid.wait();

	stderr.write(" ".replicate(Git.CommitID.init.toString().length), "\r"); stderr.flush();

	if (found)
		return 0;
	stderr.writeln("Not found.");
	return 1;
}

mixin main!(funopt!git_find_child_commit);
