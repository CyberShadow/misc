#!/usr/bin/env nix-shell
/+ dub.sdl:
 dependency "ae" version="==0.0.3543"
+/

/*
  Copies Git objects from one repository to another, and nothing else.

  Can be useful in creating deterministic copies of Git repositories,
  containing only a specific revision and its closure.
*/

/*
#! nix-shell -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/0ef56bec7281e2372338f2dfe7c13327ce96f6bb.tar.gz
#! nix-shell -i 'dub --single'
#! nix-shell -p dub -p dmd -p nix -p git
#! nix-shell --pure
*/

module git_copy_revs;

import std.conv;
import std.format;
import std.stdio;

import ae.sys.git;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;

void program(
	string sourceRepo,
	string targetRepo,
	string rev,
	bool shallow,
)
{
	auto source = Git(sourceRepo);
	auto target = Git(targetRepo);

	auto sourceObjectReader = source.createObjectReader();
	auto targetObjectWriter = target.createObjectWriter();

	HashSet!(Git.OID) seen;

	void copyObject(Git.OID oid, scope void delegate(Git.Object object) recurse)
	{
		if (oid in seen)
			return;
		seen.add(oid);

		Git.Object obj;
		try
			obj = sourceObjectReader.read(oid);
		catch (Exception e)
		{
			// Can happen with sparse clones
			stderr.writefln("Error reading %s: %s", oid.toString(), e.msg);
			return;
		}
		recurse(obj);
		targetObjectWriter.write(obj);
	}

	void copyBlob(Git.BlobID oid)
	{
		copyObject(oid, (obj) {});
	}

	void copyTree(Git.TreeID tid)
	{
		copyObject(tid, (obj) {
			auto tree = obj.parseTree();

			foreach (entry; tree)
				switch (entry.mode)
				{
					case octal!100644: // file
					case octal!100755: // executable file
						copyBlob(Git.BlobID(entry.hash));
						break;
					case octal! 40000: // tree
						copyTree(Git.TreeID(entry.hash));
						break;
					case octal!120000: // symlink
					case octal!160000: // submodule
						break;
					default:
						throw new Exception("Unknown git file mode: %o".format(entry.mode));
				}
		});
	}

	void copyCommit(Git.CommitID cid)
	{
		copyObject(cid, (obj) {
			auto commit = obj.parseCommit();

			copyTree(commit.tree);
			if (!shallow)
				foreach (parent; commit.parents)
					copyCommit(parent);
		});
	}

	copyCommit(Git.CommitID(rev));
}

mixin main!(funopt!program);
