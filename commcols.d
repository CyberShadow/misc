/**
   commcols - show common lines as colums

   This tool shows which (pre-sorted) files have which lines.

   Example:
   - 1.txt has the lines: A B C
   - 2.txt has the lines: C D E
   - 3.txt has the lines: A C E
   - commcols 1.txt 2.txt 3.txt will show:

	 Y       Y   A
	 Y           B
	 Y   Y   Y   C
		 Y       D
		 Y   Y   E
*/

import std.algorithm.iteration;
import std.algorithm.setops;
import std.array;
import std.range;
import std.stdio;
import std.typecons;

void main(string[] args)
{
	auto files =
		iota(args.length - 1)
		.map!(fi =>
			File(args[1 + fi])
			.byLine
			.map!(line => tuple(line, fi))
		).array;

	bool[] cols;
	string str;
	void flush()
	{
		if (cols is null)
			cols = new bool[files.length];
		else
		{
			writefln("%-(%s\t%|%)%s", cols.map!(present => present ? "Y" : ""), str);
			cols[] = false;
		}
	}

	// The heavy lifting is done by multiwayMerge.
	foreach (t; multiwayMerge!((a, b) => a[0] < b[0])(files))
	{
		if (t[0] != str)
		{
			flush();
			str = t[0].dup;
		}
		cols[t[1]] = true;
	}
	flush();
}
