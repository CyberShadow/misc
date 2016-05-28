import std.algorithm;
import std.conv;
import std.datetime;
import std.file;

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

void main()
{
	auto i3 = new I3Connection();

	auto localTz = PosixTimeZone.getTimeZone("Europe/Chisinau");

	enum Block
	{
	//	logs,
		nowPlaying,
		volumeIcon,
		volume,
		loadIcon,
		load,
		timeLocal,
		timeUTC,
	}

	BarBlock[enumLength!Block] blocks;

	// Update time and other stuff updated every second.
	void updateTime()
	{
		auto now = Clock.currTime();

		// Load

		blocks[Block.loadIcon].full_text = text(wchar(FontAwesome.fa_tasks));
		blocks[Block.loadIcon].min_width = 10;
		blocks[Block.loadIcon].separator = false;

		blocks[Block.load].full_text = readText("/proc/loadavg").splitter(" ").front;

		// Time

		auto clockIcon = text(wchar(FontAwesome.fa_clock_o)) ~ "  ";

		auto local = now;
		local.timezone = localTz;
		blocks[Block.timeLocal].full_text = clockIcon ~ local.formatTime!`D Y-m-d H:i:s O`;
		blocks[Block.timeLocal].background = '#' ~ timeColor(local).toHex();

		blocks[Block.timeUTC].full_text = clockIcon ~ now.formatTime!`D Y-m-d H:i:s \U\T\C`;
		blocks[Block.timeUTC].background = '#' ~ timeColor(now).toHex();

		// Send!

		i3.send(blocks[]);
		setTimeout(&updateTime, 1.seconds - now.fracSecs);
	}
	updateTime();

	void updatePulse()
	{
		auto volume = getVolume();
		wchar icon = FontAwesome.fa_volume_off;
		try
		{
			auto n = volume[0..$-1].to!int();
			icon =
				n == 0 ? FontAwesome.fa_volume_off :
				n < 50 ? FontAwesome.fa_volume_down :
				         FontAwesome.fa_volume_up;
		}
		catch {}

		blocks[Block.volumeIcon].full_text = text(icon);
		blocks[Block.volumeIcon].min_width = 10;
		blocks[Block.volumeIcon].separator = false;

		blocks[Block.volume].full_text = volume;
		blocks[Block.volume].min_width_str = "100%";
		blocks[Block.volume].alignment = "right";
		i3.send(blocks[]);
	}
	updatePulse();
	pulseSubscribe(&updatePulse);

	void updateMpd()
	{
		auto status = getMpdStatus();
		wchar icon;
		switch (status.status)
		{
			case "playing":
				icon = FontAwesome.fa_play;
				break;
			case "paused":
				icon = FontAwesome.fa_pause;
				break;
			case null:
				icon = FontAwesome.fa_stop;
				break;
			default:
				icon = FontAwesome.fa_music;
				break;
		}
		blocks[Block.nowPlaying].full_text = text(icon) ~ "  " ~ status.nowPlaying;
		i3.send(blocks[]);
	}
	updateMpd();
	mpdSubscribe(&updateMpd);

/*
	processSubscribe(["journalctl", "--follow"],
		(const(char)[] line)
		{
			blocks[Block.logs].full_text = line.idup;
			i3.send(blocks[]);
		});
*/

	socketManager.loop();
}

void processSubscribe(string[] args, void delegate(const(char)[]) callback)
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
			callback(line);
		};
}
	
RGB timeColor(SysTime time)
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
