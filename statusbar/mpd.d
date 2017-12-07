import core.sys.posix.unistd;

import std.conv;
import std.process;
import std.string;

import ae.net.asockets;

void mpdSubscribe(void delegate() callback)
{
	auto p = pipeProcess(["mpc", "idleloop"], Redirect.stdout);
	auto sock = new FileConnection(p.stdout.fileno.dup);

	sock.handleReadData =
		(Data data)
		{
			callback();
		};
	sock.handleDisconnect =
		(string reason, DisconnectType type)
		{
			mpdSubscribe(callback);
		};
}

struct MpdStatus
{
	string nowPlaying;
	string status;
	int volume = -1;
}

MpdStatus getMpdStatus()
{
	auto result = execute(["mpc"]);
	MpdStatus status;
	if (result.status == 0)
	{
		auto lines = result.output.strip().splitLines();
		if (lines.length == 3)
		{
			status.nowPlaying = lines[0];
			status.status = lines[1].split()[0][1..$-1];
			try
				status.volume = lines[2][7..10].strip.to!int;
			catch (Exception) {}
		}
	}
	return status;
}
