#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Finds a file at a given path with the given SHA1, anywhere in the
   current repository's history starting with the current commit.
*/

module git_find_file_with_sha1;

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
import std.stdio;
import std.string;

int git_find_file_with_sha1(
	bool all,
	bool first,
	string pathStr,
	string sha1,
)
{
	auto repo = Git(".");
	auto reader = repo.createObjectReader();

	auto path = pathStr.split("/");
	// Current search heads for breadth-first search
	Git.CommitID[] commits = [repo.query(`rev-parse`, `HEAD`).I!(c => Git.CommitID(c))];

	bool[Git.BlobID] blobCache;
	bool checkBlobHash(Git.BlobID blobHash)
	{
		if (blobHash.toString().startsWith(sha1))
			return true;
		return blobCache.require(blobHash, {
			auto blob = reader.read(blobHash).data;
			return blob.getDigestString!SHA1().toLower == sha1;
		}());
	}

	struct CommitResult { enum Status { gone, bad, good } Status status; Git.CommitID[] parents; }
	CommitResult[Git.CommitID] commitCache;
	CommitResult checkCommitHash(Git.CommitID commitHash)
	{
		return commitCache.require(commitHash, {
			auto commit = reader.read(commitHash).parseCommit();

			CommitResult result;
			result.parents = commit.parents;

			Git.OID fileHash = commit.tree;
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

			result.status = checkBlobHash(Git.BlobID(fileHash)) ? CommitResult.Status.good : CommitResult.Status.bad;
			return result;
		}());
	}

	HashSet!(Git.CommitID) visited;
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
