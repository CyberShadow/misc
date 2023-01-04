/// Automatically mute/unmute an application depending on the title of the focused window.
/// Mainly intended for games with non-configurable pause/mute-on-unfocus.
/// Configuration file: ~/.config/appmute.txt
/// Configuration format: <the program's application.name PA property> <TAB> <window title>
module appmute;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.conv;
import std.file;
import std.json;
import std.path;
import std.process;
import std.stdio;
import std.string;
import std.typecons;

import ae.sys.cmd : query, run;
import ae.sys.file : createLinkTargets;
import ae.sys.persistence.core;

void main()
{
	auto fn = "~/.config/appmute.txt".expandTilde;
	createLinkTargets(fn, true);
	auto rules = FileCache!((string fn) => fn
		.readText
		.splitLines
		.filter!(line => line.length && !line.startsWith("#") && line.canFind("\t"))
		.map!((line) { auto parts = line.findSplit("\t"); return tuple(parts[2], parts[0]); })
		.assocArray
	)(fn);

	auto p = pipe();
	auto pid = spawnProcess(["xtitle", "-s"], stdin, p.writeEnd);
	auto f = p.readEnd;
	string oldTitle;
	while (!f.eof)
	{
		void handleTitle(string title, bool mute)
		{
			string applicationName = rules.get(title, null);
			if (applicationName)
			{
				auto action = ["Unmuting", "Muting"][mute];
				stderr.writefln("%s %s for %s", action, applicationName, title);
				auto json = query(["pactl", "-f", "json", "list", "sink-inputs"]).parseJSON();
				foreach (sinkInput; json.array)
					if (sinkInput["properties"]["application.name"].str == applicationName)
					{
						auto index = sinkInput["index"].integer;
						stderr.writefln("> %s %d", action, index);
						try
							run(["pactl", "set-sink-input-mute", index.to!string(), mute.to!string()]);
						catch (Exception e)
							stderr.writefln(">> %s", e.msg);
					}
			}
		}

		auto newTitle = f.readln().chomp();
		handleTitle(oldTitle, true);
		handleTitle(newTitle, false);
		oldTitle = newTitle;
	}
}
