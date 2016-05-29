import std.algorithm;
import std.conv;
import std.datetime;
import std.file;
import std.functional;

import ae.net.asockets;
import ae.sys.timing;
import ae.utils.graphics.color;
import ae.utils.meta;
import ae.utils.meta.args;
import ae.utils.time.format;

import fontawesome;
import i3;
import i3conn;
import mpd;
import pulse;

I3Connection conn;

class Block
{
protected:
	static BarBlock*[] blocks;

	static void send()
	{
		conn.send(blocks);
	}
}

class TimerBlock : Block
{
	abstract void update(SysTime now);

	this()
	{
		if (!instances.length)
			onTimer();
		instances ~= this;
	}

	static TimerBlock[] instances;

	static void onTimer()
	{
		auto now = Clock.currTime();
		setTimeout(toDelegate(&onTimer), 1.seconds - now.fracSecs);
		foreach (instance; instances)
			instance.update(now);
		send();
	}
}

final class TimeBlock : TimerBlock
{
	BarBlock block;
	immutable(TimeZone) tz;

	static immutable iconStr = text(wchar(FontAwesome.fa_clock_o)) ~ "  ";

	this(immutable(TimeZone) tz)
	{
		this.tz = tz;
		blocks ~= &block;
	}

	override void update(SysTime now)
	{
		auto local = now;
		local.timezone = tz;
		block.full_text = iconStr ~ local.formatTime!`D Y-m-d H:i:s O`;
		block.background = '#' ~ timeColor(local).toHex();
	}

	static RGB timeColor(SysTime time)
	{
		auto day = 1.days.total!"hnsecs";
		time += time.utcOffset;
		auto stdTime = time.stdTime;
		//stdTime += stdTime * 3600;
		ulong tod = stdTime % day;

		enum l = 0x40;
		enum L = l*3/2;

		static const RGB[] points =
			[
				RGB(0, 0, L),
				RGB(0, l, l),
				RGB(0, L, 0),
				RGB(l, l, 0),
				RGB(L, 0, 0),
				RGB(l, 0, l),
			];

		auto slice = day / points.length;

		auto n = tod / slice;
		auto a = points[n];
		auto b = points[(n + 1) % $];

		auto sliceTime = tod % slice;

		return RGB.itpl(a, b, cast(int)(sliceTime / 1_000_000), 0, cast(int)(slice / 1_000_000));
	}
}

final class LoadBlock : TimerBlock
{
	BarBlock icon, block;

	this()
	{
		icon.full_text = text(wchar(FontAwesome.fa_tasks));
		icon.min_width = 10;
		icon.separator = false;
		blocks ~= &icon;
		blocks ~= &block;
	}

	override void update(SysTime now)
	{
		block.full_text = readText("/proc/loadavg").splitter(" ").front;
	}
}

final class PulseBlock : Block
{
	BarBlock icon, block;

	this()
	{
		icon.min_width = 15;
		icon.separator = false;

		block.min_width_str = "100%";
		block.alignment = "right";

		blocks ~= &icon;
		blocks ~= &block;

		pulseSubscribe(&update);
		update();
	}

	void update()
	{
		auto volume = getVolume();
		wchar iconChar = FontAwesome.fa_volume_off;
		try
		{
			auto n = volume[0..$-1].to!int();
			iconChar =
				n == 0 ? FontAwesome.fa_volume_off :
				n < 50 ? FontAwesome.fa_volume_down :
				         FontAwesome.fa_volume_up;
		}
		catch {}

		icon.full_text = text(iconChar);
		block.full_text = volume;

		send();
	}
}

final class MpdBlock : Block
{
	BarBlock block;

	this()
	{
		blocks ~= &block;
		mpdSubscribe(&update);
		update();
	}

	void update()
	{
		auto status = getMpdStatus();
		wchar iconChar;
		switch (status.status)
		{
			case "playing":
				iconChar = FontAwesome.fa_play;
				break;
			case "paused":
				iconChar = FontAwesome.fa_pause;
				break;
			case null:
				iconChar = FontAwesome.fa_stop;
				break;
			default:
				iconChar = FontAwesome.fa_music;
				break;
		}

		block.full_text = text(iconChar) ~ "  " ~ status.nowPlaying;
		send();
	}
}

class ProcessBlock : Block
{
	BarBlock block;

	this(string[] args)
	{
		import std.process;
		auto p = pipeProcess(args, Redirect.stdout);
		auto sock = new FileConnection(p.stdout);
		auto lines = new LineBufferedAdapter(sock);
		lines.delimiter = "\n";

		lines.handleReadData =
			(Data data)
			{
				auto line = cast(char[])data.contents;
				block.full_text = line.idup;
				send();
			};

		blocks ~= &block;
	}
}

void main()
{
	conn = new I3Connection();

	// System log
	//new ProcessBlock(["journalctl", "--follow"]);

	// Current window title
	new ProcessBlock(["xtitle", "-s"]);

	// Current playing track
	new MpdBlock();

	// Volume
	new PulseBlock();

	// Load
	new LoadBlock();

	// UTC time
	new TimeBlock(UTC());

	// Local time
	new TimeBlock(PosixTimeZone.getTimeZone("Europe/Chisinau"));
	
	socketManager.loop();
}
