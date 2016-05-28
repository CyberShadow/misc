import std.process;
import std.string;

import ae.net.asockets;

void pulseSubscribe(void delegate() callback)
{
	auto p = pipeProcess(["pactl", "subscribe"], Redirect.stdout);
	auto sock = new FileConnection(p.stdout);
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

string getVolume()
{
	auto result = execute(["pactl", "list", "sinks"]);
	if (result.status == 0)
		foreach (line; result.output.lineSplitter)
			if (line.startsWith("	Volume: "))
				return line.split()[4];
	return "?%";
}
