import core.sys.posix.unistd;

import std.algorithm.searching;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.sys.inotify;
import ae.sys.timing;

struct Volume
{
	bool known, muted;
	int percent;
}

class Audio
{
	abstract string getSymbol();
	abstract string getSymbolColor();
	abstract void subscribe(void delegate() callback);
	abstract void unsubscribe();
	abstract void runControlPanel();

	Volume getVolume()
	{
		Volume volume;
		try
		{
			auto result = execute(["volume-get"]);
			if (result.status == 0 && result.output.length)
			{
				volume.known = true;
				auto output = result.output;
				if (output.endsWith("M"))
				{
					volume.muted = true;
					output = output[0..$-1];
				}
				volume.percent = output.to!int;
			}
		}
		catch (Exception e)
			stderr.writeln("Error getting volume: " ~ e.msg);
		return volume;
	}
}

enum AudioAPI
{
	none,
	alsa,
	pulseAudio
}

AudioAPI getAudioAPI()
{
	try
	{
		switch (readLink("/etc/asound.conf"))
		{
			case "asound-native.conf":
				return AudioAPI.alsa;
			case "asound-pulse.conf":
				return AudioAPI.pulseAudio;
			default:
		}
	}
	catch (Exception e) {}
	return AudioAPI.none;
}

void listenForAPIChange(void delegate() callback)
{
	void register()
	{
		iNotify.add("/etc/asound.conf", INotify.Mask.removeSelf | INotify.Mask.dontFollow,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				stderr.writeln(mask);
				if (mask == INotify.Mask.removeSelf)
					callback();
				if (mask == INotify.Mask.ignored)
					register();
			}
		);
	}

	register();
}

Audio getAudio(AudioAPI api)
{
	final switch (api)
	{
		case AudioAPI.none:
			return new NoAudio();
		case AudioAPI.alsa:
			return new ALSA();
		case AudioAPI.pulseAudio:
			return new Pulse();
	}
}

private:

class NoAudio : Audio
{
	override string getSymbol() { return "?"; }
	override string getSymbolColor() { return "#666666"; }

	override void subscribe(void delegate() callback) { callback(); }
	override void unsubscribe() {}

	override Volume getVolume() { return Volume.init; }
	override void runControlPanel() {}
}

class Pulse : Audio
{
	ProcessPipes p;
	bool subscribed;

	override string getSymbol() { return "P"; }
	override string getSymbolColor() { return "#bbbbff"; }

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
				p = ProcessPipes.init;
				if (subscribed)
					setTimeout({ if (subscribed) subscribe(callback); }, 1.seconds);
			};

		callback();
	}

	override void unsubscribe()
	{
		subscribed = false;
		if (p.pid)
			p.pid.kill();
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

	override string getSymbol() { return "A"; }
	override string getSymbolColor() { return "#aaffcc"; }

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
				p = ProcessPipes.init;
				if (subscribed)
					setTimeout({ if (subscribed) subscribe(callback); }, 1.seconds);
			};

		callback();
	}

	override void unsubscribe()
	{
		subscribed = false;
		if (p.pid)
			p.pid.kill();
	}

	override void runControlPanel()
	{
		spawnProcess(["t", "alsamixer"]).wait();
	}
}
