#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3236"
+/

/**
   Finds all commits which reference the given commit as a parent.
   Searches all commit objects, whether they're reachable or not.
*/

module git_find_child_commit;

private:

import ae.sys.git;
import ae.utils.array;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta;
import ae.utils.text;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.digest.sha;
import std.process;
import std.stdio;
import std.string;

int git_find_child_commit(
	string parentCommitID,
)
{
	auto parsedParentCommitID = Git.CommitID(parentCommitID);

	auto repo = Git(".");
	auto reader = repo.createObjectReader();

	auto p = repo.pipe(["cat-file", "--batch-check", "--batch-all-objects"]);
	bool found;

	foreach (oline; p.stdout.byLine)
	{
		try
		{
			auto line = oline;
			auto oid = Git.OID(line.skipUntil(' '));
			auto type = line.skipUntil(' ', true);
			if (type != "commit")
				continue;

			stderr.write(oid.toString(), "\r"); stderr.flush();
			auto commit = reader.read(oid).parseCommit();
			foreach (parent; commit.parents)
				if (parent == parsedParentCommitID)
				{
					writeln(oid.toString());
					found = true;
				}
		}
		catch (Exception e)
			stderr.writeln("Error with " ~ oline ~ ": " ~ e.msg);
	}
	p.pid.wait();

	stderr.write(" ".replicate(Git.CommitID.init.toString().length), "\r"); stderr.flush();

	if (found)
		return 0;
	stderr.writeln("Not found.");
	return 1;
}

mixin main!(funopt!git_find_child_commit);
