/**
   Finds a file at a given path with the given SHA1, anywhere in the
   current repository's history starting with the current commit.
*/

module git_find_file_with_sha1;

import ae.sys.git;
import ae.utils.array;
import ae.utils.digest;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.meta;
import ae.utils.text;

import std.algorithm.iteration;
import std.array;
import std.digest.sha;
import std.stdio;
import std.string;

int git_find_file_with_sha1(
	bool all,
	string pathStr,
	string sha1,
)
{
	auto repo = Repository(".");
	auto reader = repo.createObjectReader();

	auto path = pathStr.split("/");
	// Current search heads for breadth-first search
	Hash[] commits = [repo.query(`rev-parse`, `HEAD`).toCommitHash()];

	string[Hash] hashCache;
	HashSet!Hash visited;
	bool found;

commitLoop:
	while (commits.length)
	{
		auto commitHash = commits.shift();
			if (commitHash in visited)
				continue;
			visited.add(commitHash);
		auto commit = reader.read(commitHash).parseCommit();
		auto fileHash = commit.tree;
		foreach (dir; path)
		{
			auto match = fileHash
				.I!(t => reader.read(t))
				.parseTree()
				.filter!(e => e.name == dir);
			if (match.empty)
				continue commitLoop;
			fileHash = match
				.front
				.hash;
		}

		// stderr.writeln(fileHash.toString());
		if (hashCache.require(fileHash, reader.read(fileHash).data.getDigestString!SHA1().toLower) == sha1)
		{
			writeln(commitHash.toString());
			found = true;
			if (!all)
				return 0;
		}
		commits ~= commit.parents;
	}
	if (found)
		return 0;
	stderr.writeln("Not found.");
	return 1;
}

mixin main!(funopt!git_find_file_with_sha1);
