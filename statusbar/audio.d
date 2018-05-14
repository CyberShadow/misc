import core.sys.posix.unistd;

import std.algorithm.searching;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.sys.timing;

struct Volume
{
	bool known, muted;
	int percent;
}

class Audio
{
	abstract void subscribe(void delegate() callback);
	abstract void unsubscribe();
	abstract Volume getVolume();
	abstract void runControlPanel();
}

Audio getAudio()
{
	if (readLink("/etc/asound.conf") == "asound-native.conf")
		return new ALSA();
	else
		return new Pulse();
}

private:

class Pulse : Audio
{
	ProcessPipes p;
	string sinkName;
	bool subscribed;

	this()
	{
		try
		{
			auto result = execute(["audio-get-pa-sink"], null, Config.stderrPassThrough);
			enforce(result.status == 0);
			sinkName = result.output.strip();
		}
		catch (Exception)
			sinkName = "0";
	}

	override void subscribe(void delegate() callback)
	{
		subscribed = true;
		p = pipeProcess(["pactl", "subscribe"], Redirect.stdout);
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

		lines.handleDisconnect =
			(string reason, DisconnectType type)
			{
				stderr.writeln("pactl disconnect: " ~ reason);
				callback();
				wait(p.pid);
				if (subscribed)
					setTimeout({ subscribe(callback); }, 1.seconds);
			};

		callback();
	}

	override void unsubscribe()
	{
		subscribed = false;
		p.pid.kill();
	}

	override Volume getVolume()
	{
		Volume volume;
		auto result = execute(["pactl", "list", "sinks"]);
		bool inSelectedSink;
		if (result.status == 0)
		{
			foreach (line; result.output.lineSplitter)
				if (line.skipOver("\tName: "))
					inSelectedSink = line == sinkName;
				else
				if (line.skipOver("\tVolume: ") && inSelectedSink)
				{
					volume.percent = line.split()[3].chomp("%").to!int;
					volume.known = true;
				}
				else
				if (line.skipOver("\tMute: ") && inSelectedSink)
					volume.muted = line == "yes";
		}
		return volume;
	}

	override void runControlPanel()
	{
		spawnProcess(["x", "pavucontrol"]).wait();
	}
}

class ALSA : Audio
{
	ProcessPipes p;
	bool subscribed;

	override void subscribe(void delegate() callback)
	{
		subscribed = true;
		p = pipeProcess(["script", "/dev/null", "-c", "alsamixer"], Redirect.stdin | Redirect.stdout, ["TERM":"xterm"]);
		auto sock = new FileConnection(p.stdout.fileno.dup);

		sock.handleReadData =
			(Data data)
			{
				callback();
			};

		sock.handleDisconnect =
			(string reason, DisconnectType type)
			{
				stderr.writeln("alsamixer disconnect: " ~ reason);
				callback();
				wait(p.pid);
				if (subscribed)
					setTimeout({ subscribe(callback); }, 1.seconds);
			};

		callback();
	}

	override void unsubscribe()
	{
		subscribed = false;
		p.pid.kill();
	}

	override Volume getVolume()
	{
		Volume volume;
		auto result = execute(["amixer", "sget", "Master"]);
		if (result.status == 0)
		{
			foreach (line; result.output.lineSplitter)
				if (line.skipOver("  Mono: "))
				{
					auto parts = line.split();
					enforce(parts.length == 5, "Unrecognized amixer output");
					volume.known = true;
					volume.muted = parts[4] == "[off]";
					volume.percent = parts[2][1..$-2].to!int;
					break;
				}
		}
		return volume;
	}

	override void runControlPanel()
	{
		spawnProcess(["t", "alsamixer"]).wait();
	}
}
