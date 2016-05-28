import std.socket;
import std.stdio;

import ae.net.asockets;
import ae.utils.json;
import ae.sys.timing;

import i3;

class I3Connection
{
	FileConnection stdinSock, stdoutSock;

	this()
	{
		stdinSock = new FileConnection(stdin);
		stdoutSock = new FileConnection(stdout);

		stdinSock.handleReadData =
			(Data data)
			{
				//stdoutSock.send(data);
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

	void send(BarBlock[] blocks)
	{
		stdoutSock.send(Data(blocks.toJson()));
		stdoutSock.send(Data(",\n"));
	}
}
