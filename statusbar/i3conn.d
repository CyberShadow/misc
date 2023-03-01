import std.algorithm.searching;
import std.exception;
import std.socket;
import std.stdio;

import ae.net.asockets;
import ae.utils.json;
import ae.sys.timing;

import i3;

class I3Connection
{
	void delegate(BarClick) clickHandler;

	this()
	{
		stdinSock = new FileConnection(stdin.fileno);
		stdoutSock = new FileConnection(stdout.fileno);

		auto stdinLines = new LineBufferedAdapter(stdinSock);
		stdinLines.delimiter = "\n";

		uint count;
		stdinLines.handleReadData =
			(Data data)
			{
				auto str = cast(const(char)[])data.contents;
				scope(exit) count++;
				if (count == 0)
				{
					enforce(str == "[", "Bad i3 line: " ~ str);
					return;
				}
				else
				if (count > 1)
					enforce(str.skipOver(","));

				if (clickHandler)
					clickHandler(jsonParse!BarClick(str));
			};
		stdinSock.handleDisconnect =
			(string reason, DisconnectType type)
			{
				stdoutSock.disconnect("stdin EOF");
			};

		BarHeader header;
		header.click_events = true;
		stdoutSock.send(Data(header.toJson()));
		stdoutSock.send(Data("\n[\n"));
	}

	void send(BarBlock*[] blocks)
	{
		stdoutSock.send(Data(blocks.toJson()));
		stdoutSock.send(Data(",\n"));
	}

private:
	FileConnection stdinSock, stdoutSock;
}
