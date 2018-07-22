module sort_binary_order;

import ae.sys.file;
import ae.utils.text;

import std.exception;
import std.stdio;

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
