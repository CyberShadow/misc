/// Automatically switch keyboard layouts depending on the title of the focused window.
/// Mainly intended for games with non-configurable key bindings.
/// Currently the configuration is hard-coded.
module applayout;

import std.conv;
import std.process;
import std.stdio;
import std.string;

void main()
{
	auto p = pipe();
	auto pid = spawnProcess(["xtitle", "-s"], stdin, p.writeEnd);
	auto f = p.readEnd;
	int oldLayout;
	while (!f.eof)
	{
		auto title = f.readln().chomp();
		int layout;
		switch (title)
		{
			case "Uurnog":
			case "Tallowmere":
			case "UNDERTALE":
				layout = 2; break;
			default:
				layout = 1; break;
		}
		if (layout != oldLayout)
		{
			stderr.writefln("Switching layout from %d to %d for %s", oldLayout, layout, title);
			spawnProcess(["xkblayout", text(layout)]).wait();
			oldLayout = layout;
		}
	}
}
