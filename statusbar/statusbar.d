import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.functional;
import std.stdio;
import std.string;
import std.process;

import ae.net.asockets;
import ae.sys.inotify;
import ae.sys.timing;
import ae.utils.graphics.color;
import ae.utils.meta;
import ae.utils.meta.args;
import ae.utils.path;
import ae.utils.time.format;

import fontawesome;
import i3;
import i3conn;
import mpd;
import pulse;

I3Connection conn;

enum iconWidth = 11;

class Block
{
private:
	static BarBlock*[] blocks;
	static Block[] blockOwners;

protected:
	final void addBlock(BarBlock* block)
	{
		block.instance = text(blocks.length);
		blocks ~= block;
		blockOwners ~= this;
	}

	static void send()
	{
		conn.send(blocks);
	}

	void handleClick(BarClick click)
	{
	}

public:
	static void clickHandler(BarClick click)
	{
		try
		{
			auto n = click.instance.to!size_t;
			enforce(n < blockOwners.length);
			blockOwners[n].handleClick(click);
		}
		catch (Throwable e)
			spawnProcess(["notify-send", e.msg]).wait();
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
		update(Clock.currTime());
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

class TimeBlock(string timeFormat) : TimerBlock
{
	BarBlock block;
	immutable(TimeZone) tz;

	static immutable iconStr = text(wchar(FontAwesome.fa_clock_o)) ~ "  ";

	this(immutable(TimeZone) tz)
	{
		this.tz = tz;
		addBlock(&block);
	}

	override void update(SysTime now)
	{
		auto local = now;
		local.timezone = tz;
		block.full_text = iconStr ~ local.formatTime!timeFormat;
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

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			spawnProcess(["t", "sh", "-c", "cal -y ; read -n 1"]).wait();
	}
}

class UtcTimeBlock : TimeBlock!`D Y-m-d H:i:s \U\T\C`
{
	this() { super(UTC()); }
}

alias TzTimeBlock = TimeBlock!`D Y-m-d H:i:s O`;

final class LoadBlock : TimerBlock
{
	BarBlock icon, block;

	this()
	{
		icon.full_text = text(wchar(FontAwesome.fa_tasks));
		icon.min_width = iconWidth;
		icon.separator = false;
		addBlock(&icon);
		addBlock(&block);
	}

	override void update(SysTime now)
	{
		block.full_text = readText("/proc/loadavg").splitter(" ").front;
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			spawnProcess(["t", "htop"]).wait();
	}
}

final class PulseBlock : Block
{
	BarBlock icon, block;

	this()
	{
		icon.min_width = iconWidth;
		icon.separator = false;
		icon.name = "icon";

		block.min_width_str = "100%";
		block.alignment = "right";

		addBlock(&icon);
		addBlock(&block);

		pulseSubscribe(&update);
		update();
	}

	void update()
	{
		auto volume = getVolume();
		wchar iconChar = FontAwesome.fa_volume_off;
		string volumeStr = "???%";
		if (volume.known)
		{
			auto n = volume.percent;
			iconChar =
				volume.muted ? FontAwesome.fa_volume_off :
				n == 0 ? FontAwesome.fa_volume_off :
				n < 50 ? FontAwesome.fa_volume_down :
				         FontAwesome.fa_volume_up;
			volumeStr = "%3d%%".format(volume.percent);
		}

		icon.full_text = text(iconChar);
		block.full_text = volumeStr;

		send();
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			if (click.name == "icon")
				spawnProcess(["pactl", "set-sink-mute", sinkName, "toggle"]).wait();
			else
				spawnProcess(["x", "pavucontrol"]).wait();
		else
		if (click.button == 3)
			spawnProcess(["speakers"], stdin, File(nullFileName, "w")).wait();
		else
		if (click.button == 4)
			spawnProcess(["pactl", "set-sink-volume", sinkName, "+5%"]).wait();
		else
		if (click.button == 5)
			spawnProcess(["pactl", "set-sink-volume", sinkName, "-5%"]).wait();
	}
}

final class MpdBlock : Block
{
	BarBlock icon, block;
	string status;

	this()
	{
		icon.min_width = iconWidth;
		icon.separator = false;
		icon.name = "icon";

		addBlock(&icon);
		addBlock(&block);
		mpdSubscribe(&update);
		update();
	}

	void update()
	{
		auto status = getMpdStatus();
		this.status = status.status;
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

		icon.full_text = text(iconChar);
		block.full_text = status.nowPlaying;
		send();
	}

	override void handleClick(BarClick click)
	{
		if (click.name == "icon")
		{
			string cmd;
			if (status == "playing")
				cmd = click.button == 1 ? "pause" : "stop";
			else
				cmd = "play";
			spawnProcess(["mpc", cmd], stdin, File("/dev/null", "wb")).wait();
		}
		else
			if (click.button == 1)
			{
				spawnProcess(["x", "cantata"]).wait();
			}
	}
}

class ProcessBlock : Block
{
	BarBlock block;
	void delegate(BarClick) clickHandler;

	this(string[] args, void delegate(BarClick) clickHandler = null)
	{
		this.clickHandler = clickHandler;

		import core.sys.posix.unistd;
		auto p = pipeProcess(args, Redirect.stdout);
		auto sock = new FileConnection(p.stdout.fileno.dup);
		auto lines = new LineBufferedAdapter(sock);
		lines.delimiter = "\n";

		lines.handleReadData =
			(Data data)
			{
				auto line = cast(char[])data.contents;
				block.full_text = line.idup;
				send();
			};

		addBlock(&block);
	}

	override void handleClick(BarClick click)
	{
		if (clickHandler)
			clickHandler(click);
	}
}

final class BrightnessBlock : Block
{
	BarBlock icon, block;

	this()
	{
		icon.full_text = text(wchar(FontAwesome.fa_sun_o));
		icon.min_width = iconWidth;
		icon.separator = false;

		addBlock(&icon);
		addBlock(&block);
		update();

		iNotify.add("/tmp/pq321q-brightness", INotify.Mask.create | INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				update();
			}
		);
	}

	void update()
	{
		auto result = execute(["/home/vladimir/bin/home/pq321q-brightness-get"]);
		try
		{
			enforce(result.status == 0);
			auto value = result.output.strip().to!int;
			auto pct = value * 100 / 31;

			block.full_text = format("%3d%%", pct);
			send();
		}
		catch (Exception) {}
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 4)
			spawnProcess(["/home/vladimir/bin/home/pq321q-brightness-up"]).wait();
		else
		if (click.button == 5)
			spawnProcess(["/home/vladimir/bin/home/pq321q-brightness-down"]).wait();
	}
}

void main()
{
	conn = new I3Connection();
	conn.clickHandler = toDelegate(&Block.clickHandler);

	try
	{
		// System log
		//new ProcessBlock(["journalctl", "--follow"]);

		// Current window title
		new ProcessBlock(["xtitle", "-s"], click => click.button == 1 ? spawnProcess(["x", "rofi", "-show", "window"]).wait() : {}());

		// Current playing track
		new MpdBlock();

		// Volume
		new PulseBlock();

		// Brightness
		new BrightnessBlock();

		// Load
		new LoadBlock();

		// UTC time
		new UtcTimeBlock();

		// Local time
		new TzTimeBlock(PosixTimeZone.getTimeZone("Europe/Chisinau"));

		socketManager.loop();
	}
	catch (Throwable e)
	{
		std.file.write("statusbar-error.txt", e.toString());
		throw e;
	}
}
