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
import std.algorithm.searching;
import std.array;
import std.digest.sha;
import std.stdio;
import std.string;

int git_find_file_with_sha1(
	bool all,
	bool first,
	string pathStr,
	string sha1,
)
{
	auto repo = Repository(".");
	auto reader = repo.createObjectReader();

	auto path = pathStr.split("/");
	// Current search heads for breadth-first search
	Hash[] commits = [repo.query(`rev-parse`, `HEAD`).toCommitHash()];

	bool[Hash] blobCache;
	bool checkBlobHash(Hash blobHash)
	{
		return blobCache.require(blobHash, {
			auto blob = reader.read(blobHash).data;
			return blob.getDigestString!SHA1().toLower == sha1;
		}());
	}

	struct CommitResult { enum Status { gone, bad, good } Status status; Hash[] parents; }
	CommitResult[Hash] commitCache;
	CommitResult checkCommitHash(Hash commitHash)
	{
		return commitCache.require(commitHash, {
			auto commit = reader.read(commitHash).parseCommit();

			CommitResult result;
			result.parents = commit.parents;

			auto fileHash = commit.tree;
			foreach (dir; path)
			{
				auto match = fileHash
					.I!(t => reader.read(t))
					.parseTree()
					.filter!(e => e.name == dir);
				if (match.empty)
					return result;
				fileHash = match
					.front
					.hash;
			}

			result.status = checkBlobHash(fileHash) ? CommitResult.Status.good : CommitResult.Status.bad;
			return result;
		}());
	}

	HashSet!Hash visited;
	bool found;

	while (commits.length)
	{
		auto commitHash = commits.shift();
		if (commitHash in visited)
			continue;
		visited.add(commitHash);

		// stderr.writeln(fileHash.toString());
		auto result = checkCommitHash(commitHash);
		if (result.status == CommitResult.Status.gone)
			continue;

		bool ok = result.status == CommitResult.Status.good;
		if (first)
			ok = ok && result.parents.all!(parent => checkCommitHash(parent).status != CommitResult.Status.good);

		if (ok)
		{
			writeln(commitHash.toString());
			found = true;
			if (!all)
				return 0;
		}
		commits ~= result.parents;
	}
	if (found)
		return 0;
	stderr.writeln("Not found.");
	return 1;
}

mixin main!(funopt!git_find_file_with_sha1);
