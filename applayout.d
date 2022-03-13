/// Automatically switch keyboard layouts depending on the title of the focused window.
/// Mainly intended for games with non-configurable key bindings.
/// Configuration file: ~/.config/applayout.txt
/// Configuration format: <layout number> <TAB> <window title>
module applayout;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.typecons;

import ae.sys.persistence.core;

void main()
{
	auto rules = FileCache!((string fn) => fn
		.readText
		.splitLines
		.filter!(line => line.length && !line.startsWith("#") && line.canFind("\t"))
		.map!((line) { auto parts = line.findSplit("\t"); return tuple(parts[2], parts[0].to!int); })
		.assocArray
	)("~/.config/applayout.txt".expandTilde);

	auto p = pipe();
	auto pid = spawnProcess(["xtitle", "-s"], stdin, p.writeEnd);
	auto f = p.readEnd;
	int oldLayout;
	while (!f.eof)
	{
		auto title = f.readln().chomp();
		int layout = rules.get(title, 1);
		if (layout != oldLayout)
		{
			stderr.writefln("Switching layout from %d to %d for %s", oldLayout, layout, title);
			spawnProcess(["~/libexec/xkblayout".expandTilde, text(layout)]).wait();
			oldLayout = layout;
		}
	}
}
