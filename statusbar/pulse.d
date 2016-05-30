import core.sys.posix.unistd;

import std.algorithm.searching;
import std.conv;
import std.process;
import std.string;

import ae.net.asockets;

void pulseSubscribe(void delegate() callback)
{
	auto p = pipeProcess(["pactl", "subscribe"], Redirect.stdout);
	auto sock = new FileConnection(p.stdout.fileno.dup);
	auto lines = new LineBufferedAdapter(sock);
	lines.delimiter = "\n";

	lines.handleReadData =
		(Data data)
		{
			auto line = cast(char[])data.contents;
			//import std.stdio; stderr.writefln("Got %d bytes of data: %s", data.length, line);

			// Ignore our own volume queries
			if (line.startsWith("Event 'new' on client ")
			 || line.startsWith("Event 'change' on client ")
			 || line.startsWith("Event 'remove' on client "))
				return;

			callback();
		};
}

struct Volume
{
	bool known, muted;
	int percent;
}

Volume getVolume()
{
	Volume volume;
	auto result = execute(["pactl", "list", "sinks"]);
	if (result.status == 0)
	{
		foreach (line; result.output.lineSplitter)
			if (line.skipOver("\tVolume: "))
			{
				volume.percent = line.split()[3].chomp("%").to!int;
				volume.known = true;
			}
			else
			if (line.skipOver("\tMute: "))
				volume.muted = line == "yes";
			else
			if (line == "Sink #1")
				break;
	}
	return volume;
}
