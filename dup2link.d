#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Replace duplicate files under the given directories with hard
   links. Do this safely and efficiently.
*/
module dup2link;

import std.stdio;
import std.file;
import std.exception;

import ae.sys.file;
import ae.sys.console;

/*
  Delay hashing of file pairs until the first size collision.

  bySize indicates the collision state of a file size:
  - bySize[filesize] doesn't exist:
        No files with such size have been encountered.
        First file of a size is stored there.
  - bySize[filesize] exists and is not null:
        Only one file with such a size has been found so far.
        A second match promotes the pair to files[hash] and
        sets bySize[filesize] to null.
  - bySize[filesize] exists and is null:
        Multiple files with this size have been found.
        Calculate hash and check files[hash].
*/

alias ubyte[16] hash;

void main(string[] args)
{
	string[][hash] files;
	string[ulong] bySize;

	auto dirs = args[1..$];
	if (!dirs.length)
		dirs = [""];

	bool[ulong] seenFileID;

	foreach (dir; dirs)
	{
	fileLoop:
		foreach (file; fastListDir!true(dir))
		{
			auto fileID = file.getFileID();
			if (fileID in seenFileID)
				continue;

			ulong size = getSize(file);
			if (size in bySize)
			{
				// Not the first file of this size
				if (bySize[size])
				{
					// Second file of this size
					hash h = mdFile(bySize[size]);
					assert(h !in files, "Hash collision on differently-sized files");
					files[h] ~= bySize[size];
					bySize[size] = null;
					// continue adding the current file to files[] as well
				}
				hash h = mdFile(file);
				if (h in files)
				{
					foreach (oldFile; files[h])
						if (getFileID(oldFile) != fileID)
						{
							// Duplicate found
							writefln("%s == %s", oldFile, file);

							std.file.rename(file, file ~ ".dup");
							enforce(exists(oldFile), "Source file disappeared! (Directory junction?)");
							hardLink(oldFile, file);
							enforce(exists(file) && exists(file ~ ".dup") && exists(oldFile) && getFileID(oldFile) == getFileID(file));
							std.file.remove(file ~ ".dup");
							continue fileLoop;
						}
				}
				// New file
				files[h] ~= file;
			}
			else // First file of this size
				bySize[size] = file;

			seenFileID[fileID] = true;
		}
	}
}
