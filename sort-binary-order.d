#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Sort lines in binary bisection order, i.e.:
   0 1 2 3 4 5 6 7 -> 4 2 6 1 3 5 7 0

   Example use case: Non-interactively warm up a ccache cache for a
   later interactive bisection:
   git log v4.14..v4.15 --pretty=format:%H | sort-binary-order | sed 's#^#./buildver.sh #g' | bash
*/

module sort_binary_order;

import std.exception;
import std.stdio;

import ae.sys.file;
import ae.utils.text;

void main(string[] args)
{
	enforce(args.length == 1, "stdin only please");

	auto lines = (cast(string)readFile(stdin)).splitAsciiLines;

	auto order = new int[lines.length];
	auto power = 0;
	bool changed = true;
	while (changed)
	{
		changed = false;
		power++;
		auto count = 1 << power;

		foreach (n; 0..count)
			if (n & 1)
			{
				auto index = lines.length * n / count;
				if (!order[index])
				{
					order[index] = power;
					changed = true;
				}
			}
	}

	foreach (p; 1..power)
		foreach (i; 0..lines.length)
			if (order[i] == p)
				writeln(lines[i]);
}
