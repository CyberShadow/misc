/**
   An efficient i3bar data source.
*/

module statusbar;

import core.thread;

import std.algorithm.iteration;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.functional;
import std.path;
import std.regex;
import std.stdio;
import std.string;
import std.process;

import ae.net.asockets;
import ae.sys.datamm;
import ae.sys.file;
import ae.sys.inotify;
import ae.sys.timing;
import ae.utils.array;
import ae.utils.graphics.color;
import ae.utils.meta;
import ae.utils.meta.args;
import ae.utils.path;
import ae.utils.time.format;

import audio;
import fontawesome;
import i3;
import i3conn;
import mpd;

I3Connection conn;

enum iconWidth = 11;

class Block
{
private:
	static BarBlock*[] blocks;
	static Block[] blockOwners;
	string lastNotificationID = null;

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

	void showNotification(string str, string hints = null)
	{
		string[] commandLine = ["dunstify", "-t", "1000", "--printid", str];
		if (hints)
			commandLine ~= "--hints=" ~ hints;
		if (lastNotificationID)
			commandLine ~= "--replace=" ~ text(lastNotificationID);
		auto result = execute(commandLine, null, Config.stderrPassThrough);
		enforce(result.status == 0, "dunstify failed");
		lastNotificationID = result.output.strip();
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

	static immutable iconStr = text(wchar(FontAwesome.fa_clock)) ~ " ";

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
		enum day = 1.days.total!"seconds";
		time += time.utcOffset;
		auto unixTime = time.toUnixTime;
		int tod = unixTime % day;

		enum l = 0x40;
		enum L = l*3/2;

		static immutable RGB[] colors =
			[
				RGB(0, 0, L),
				RGB(0, l, l),
				RGB(0, L, 0),
				RGB(l, l, 0),
				RGB(L, 0, 0),
				RGB(l, 0, l),
			];
		alias G = Gradient!(int, RGB);
		import std.range : iota;
		import std.array : array;
		static immutable grad = G((colors.length+1).iota.map!(n => G.Point(cast(int)(day / colors.length * n), colors[n % $])).array);

		return grad.get(tod);
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			spawnProcess(["~/libexec/x".expandTilde, "~/libexec/datetime-popup".expandTilde]).wait();
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
			spawnProcess(["~/libexec/t".expandTilde, "htop"]).wait();
	}
}

final class VolumeBlock : Block
{
	BarBlock apiIcon, icon, block;
	Volume oldVolume;
	Audio audio;

	this()
	{
		apiIcon.min_width = 6;
		apiIcon.separator = false;
		apiIcon.separator_block_width = -1;
		apiIcon.name = "apiIcon";

		icon.min_width = iconWidth + 1;
		icon.separator = false;
		icon.name = "icon";

		block.min_width_str = "100%";
		block.alignment = "right";

		addBlock(&apiIcon);
		addBlock(&icon);
		addBlock(&block);

		audio = getAudio();
		audio.subscribe(&update);
		update();
	}

	void update()
	{
		auto volume = audio.getVolume();
		if (oldVolume == volume)
			return;
		oldVolume = volume;

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

		apiIcon.full_text = audio.getSymbol();
		apiIcon.color = audio.getSymbolColor();
		icon.full_text = text(iconChar);
		icon.color = volume.muted ? "#ff0000" : null;
		block.full_text = volumeStr;
		block.color = volume.percent > 100 ? "#ff0000" : null;

		send();

		showNotification("Volume: " ~
			(!volume.known
				? "???"
				: "[%3d%%]%s".format(
					volume.percent,
					volume.muted ? " [Mute]" : ""
				)),
			volume.percent > 100 ? "string:fgcolor:#ff0000" : null);
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			if (click.name == "icon")
				spawnProcess(["~/libexec/volume-mute-toggle".expandTilde]).wait();
			else
				audio.runControlPanel();
		else
		if (click.button == 3)
			spawnProcess(["~/libexec/speakers".expandTilde], stdin, File(nullFileName, "w")).wait();
		else
		if (click.button == 4)
			spawnProcess(["~/libexec/volume-up".expandTilde]).wait();
		else
		if (click.button == 5)
			spawnProcess(["~/libexec/volume-down".expandTilde]).wait();
	}
}

final class MpdBlock : Block
{
	BarBlock icon, block;
	string status;

	this()
	{
		icon.min_width = iconWidth;
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
				if (status.volume <= 0)
					iconChar = FontAwesome.fa_volume_off;
				else
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
		icon.color = status.volume == 0 ? "#ffff00" : null;
		block.full_text = status.nowPlaying ? status.nowPlaying : "";
		icon.separator = status.nowPlaying.length == 0;
		send();
	}

	override void handleClick(BarClick click)
	{
		if (click.name == "icon")
		{
			if (click.button == 1)
				spawnProcess(["~/libexec/mpc-toggle".expandTilde], stdin, File("/dev/null", "wb")).wait();
			else
				spawnProcess(["~/libexec/x", "cantata"]).wait();
		}
		else
			if (click.button == 1)
				spawnProcess(["~/libexec/x".expandTilde, "cantata"]).wait();
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
				if (!block.full_text)
					block.full_text = "";
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

final class SystemStatusBlock : TimerBlock
{
	BarBlock block;
	SysTime lastUpdate;
	bool dirty = true;

	this()
	{
		addBlock(&block);

		import core.sys.posix.unistd;
		auto p = pipeProcess(["journalctl", "--follow"], Redirect.stdout);
		auto sock = new FileConnection(p.stdout.fileno.dup);
		auto lines = new LineBufferedAdapter(sock);
		lines.delimiter = "\n";

		lines.handleReadData = (Data data) { dirty = true; };

		super();
	}

	override void update(SysTime now)
	{
		if (dirty)
		{
			auto result = execute(["~/libexec/system-status".expandTilde], /*Config.stderrPassThrough*/);
			if (result.status == 0)
			{
				block.full_text = wchar(FontAwesome.fa_check).text;
				// block.background = null;
				block.color = "#00ff00";
				block.urgent = false;
			}
			else
			if (result.status == 42)
			{
				block.full_text = wchar(FontAwesome.fa_exclamation_triangle).text;
				// block.background = null;
				block.color = "#ffff00";
				block.urgent = false;
			}
			else
			{
				block.full_text = format("\&nbsp;\&nbsp;%s\&nbsp;%s ",
					dchar(FontAwesome.fa_times),
					result.output.strip.replace("\n", " | "));
				// block.background = "#ff0000";
				block.color = null;
				block.urgent = true;
			}
			dirty = false;
		}
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 1)
			spawnProcess(["~/libexec/t".expandTilde, "sh", "-c", "~/libexec/system-status-detail ; read -n 1"]).wait();
	}
}

final class BrightnessBlock : Block
{
	BarBlock icon, block;
	int oldValue = -1;

	this()
	{
		icon.full_text = text(wchar(FontAwesome.fa_sun));
		icon.min_width = iconWidth;
		icon.separator = false;

		addBlock(&icon);
		addBlock(&block);
		update();

		enum fn = "/tmp/brightness";
		if (!fn.exists)
			fn.touch();
		iNotify.add(fn, INotify.Mask.create | INotify.Mask.modify,
			(in char[] name, INotify.Mask mask, uint cookie)
			{
				update();
			}
		);
	}

	void update()
	{
		auto result = execute(["~/libexec/brightness-get".expandTilde]);
		try
		{
			enforce(result.status == 0);
			auto value = result.output.strip().to!int;
			if (oldValue == value)
				return;
			oldValue = value;

			block.full_text = format("%3d%%", value);
			send();

			showNotification("Brightness: [%3d%%]".format(value));
		}
		catch (Exception) {}
	}

	override void handleClick(BarClick click)
	{
		if (click.button == 4)
			spawnProcess(["~/libexec/brightness-up".expandTilde]).wait();
		else
		if (click.button == 5)
			spawnProcess(["~/libexec/brightness-down".expandTilde]).wait();
	}
}

final class BatteryBlock : Block
{
	BarBlock icon, block;
	string devicePath;
	SysTime lastUpdate;

	this(string deviceMask)
	{
		auto devices = execute(["upower", "-e"])
			.output
			.splitLines
			.filter!(line => globMatch(line, deviceMask))
			.array;
		this.devicePath = devices.length ? devices[0] : null;

		icon.min_width = 17;
		icon.alignment = "center";
		icon.separator = false;
		icon.name = "icon";

		addBlock(&icon);
		addBlock(&block);

		import core.sys.posix.unistd;
		auto p = pipeProcess(["upower", "--monitor"], Redirect.stdout);
		auto sock = new FileConnection(p.stdout.fileno.dup);
		auto lines = new LineBufferedAdapter(sock);
		lines.delimiter = "\n";

		lines.handleReadData =
			(Data data)
			{
				auto now = Clock.currTime();
				if (now - lastUpdate >= 1.msecs)
				{
					lastUpdate = now;
					update();
				}
			};
	}

	void update()
	{
		wchar iconChar = FontAwesome.fa_question_circle;
		string blockText, color;

		try
		{
			enforce(devicePath, "No device");
			auto result = execute(["upower", "-i", devicePath], null, Config.stderrPassThrough);
			enforce(result.status == 0, "upower failed");

			string[string] props;
			foreach (line; result.output.splitLines())
			{
				auto parts = line.findSplit(":");
				if (!parts[1].length)
					continue;
				props[parts[0].strip] = parts[2].strip;
			}

			auto percentage = props.get("percentage", "0%").chomp("%").to!int;

			switch (props.get("state", ""))
			{
				case "charging":
					iconChar = FontAwesome.fa_bolt;
					break;
				case "fully-charged":
					iconChar = FontAwesome.fa_plug;
					break;
				case "discharging":
					switch (percentage)
					{
						case  0: .. case  20: iconChar = FontAwesome.fa_battery_empty         ; break;
						case 21: .. case  40: iconChar = FontAwesome.fa_battery_quarter       ; break;
						case 41: .. case  60: iconChar = FontAwesome.fa_battery_half          ; break;
						case 61: .. case  80: iconChar = FontAwesome.fa_battery_three_quarters; break;
						case 81: .. case 100: iconChar = FontAwesome.fa_battery_full          ; break;
						default: iconChar = FontAwesome.fa_question_circle; break;
					}

					alias G = Gradient!(int, RGB);
					static immutable grad = G([
						G.Point(10, RGB(255,   0,   0)), // red
						G.Point(30, RGB(255, 255,   0)), // yellow
						G.Point(50, RGB(255, 255, 255)), // white
					]);
					color = '#' ~ grad.get(percentage).toHex();

					break;
				default:
					iconChar = FontAwesome.fa_question_circle;
					break;
			}

			blockText = props.get("percentage", "???");
		}
		catch (Exception e)
		{
			blockText = "ERROR";
			stderr.writeln(e.msg);
		}

		icon.full_text = text(iconChar);
		block.full_text = blockText;
		block.color = color;
		send();
	}

	override void handleClick(BarClick click)
	{
		// if (click.button == 1)
		// 	spawnProcess(["~/libexec/t".expandTilde, "powertop"]).wait();
	}
}

void trackFile(string fileName, void delegate(string) onChange)
{
	if (!fileName.exists)
	{
		fileName.ensurePathExists();
		fileName.touch();
	}
	onChange(fileName);
	try
		fileName = realPath(fileName);
	catch (ErrnoException)
		return;
	iNotify.add(fileName, INotify.Mask.create | INotify.Mask.modify,
		(in char[] name, INotify.Mask mask, uint cookie) {
			stderr.writeln("Reloading " ~ fileName);
			onChange(fileName);
		}
	);
}

bool reverseLineSplitter(char[] contents, bool delegate(char[] line) lineSink)
{
	sizediff_t newline1 = -1, newline2 = -1;

	foreach_reverse (i, c; contents)
		if (c == '\n')
		{
			newline2 = newline1;
			newline1 = i;
			if (newline2 > 0)
				if (lineSink(contents[newline1 + 1.. newline2]))
					return true;
		}

	if (newline1 > 0)
		if (lineSink(contents[0 .. newline1]))
			return true;

	return false;
}

string truncateWithEllipsis(string s, size_t maxLength)
{
	auto ds = s.to!dstring;
	if (ds.length > maxLength)
		ds = ds[0 .. maxLength - 1] ~ '…';
	return ds.to!string;
}

Data tryMapFile(string fn) { try return mapFile(fn, MmMode.read); catch (Exception e) return Data.init; }

final class WorkBlock : Block
{
	BarBlock icon, block;
	enum Mode { unknown, work, play }
	Mode mode;
	string project;

	struct Def
	{
		bool work;
		Regex!char re;

		bool opEquals(ref const Def b) const { return work == b.work && re.ir == b.re.ir; }
	}
	Def[] defs;

	this()
	{
		icon.min_width = iconWidth;
		icon.separator = false;

		addBlock(&icon);
		addBlock(&block);

		trackFile(
			"~/.config/private/work/titles.txt".expandTilde,
			(string defsFn)
			{
				defs = null;
				foreach (line; defsFn.readText.splitLines)
				try
				{
					if (!line.startsWith("["))
						continue;
					line = line.findSplit("] ")[2];
					auto parts = line.findSplit("\t");
					enum Op { del, add, ins }
					auto op = parts[0].to!Op;
					line = parts[2];
					auto def = Def("-+".indexOf(line[0]).to!bool, regex(line[1 .. $]));

					final switch (op)
					{
						case Op.del: defs = defs.filter!(d => d != def).array; break;
						case Op.add: defs ~= def; break;
						case Op.ins: defs = def ~ defs; break;
					}
				}
				catch (Exception e)
					stderr.writeln(e.msg);
				// TODO: reparse log file
			}
		);

		trackFile(
			"~/.config/private/work/project.log".expandTilde,
			(string projectsFn)
			{
				auto data = tryMapFile(projectsFn);
				auto contents = cast(char[])data.contents;
				reverseLineSplitter(contents,
					(line)
					{
						project = line.findSplit("] ")[2].idup;
						update();
						return true;
					}
				);
			}
		);

		trackFile(
			"~/.local/share/xtitle.log".expandTilde,
			(string logFn)
			{
				auto data = tryMapFile(logFn);
				auto contents = cast(char[])data.contents;

				if (reverseLineSplitter(contents,
					(line)
					{
						line = line.findSplit("] ")[2];
						if (!line.length)
							return false;

						foreach (ref def; defs)
							if (line.match(def.re))
							{
								mode = def.work ? Mode.work : Mode.play;
								update();
								return true;
							}

						return false;
					}
				))
					return;

				mode = Mode.unknown;
				update();
			}
		);
	}

	Mode oldMode;
	string oldProject;

	void update()
	{
		if (mode == oldMode && project == oldProject)
			return;
		scope(success) { oldMode = mode; oldProject = project; }

		final switch (mode)
		{
			case Mode.work:
				icon.full_text = text(wchar(FontAwesome.fa_briefcase));
				block.full_text = project.truncateWithEllipsis(8);
				block.color = icon.color = "#ffff00";
				break;
			case Mode.play:
				icon.full_text = text(wchar(FontAwesome.fa_tree));
				block.full_text = "";
				block.color = icon.color = null;
				break;
			case Mode.unknown:
				icon.full_text = "🯄";
				block.color = icon.color = "#ff0000";
				block.full_text = " ";
				break;
		}
		mode.to!string.toFile("/tmp/work-mode.txt");

		new Thread({
			spawnProcess(["~/libexec/setwall".expandTilde], stdin, stderr, stderr).wait();
		}).start();

		// `swaymsg reload` restarts statusbar
		if ("WAYLAND_DISPLAY" in environment && oldMode == Mode.unknown)
		{ /* skip */ }
		else
		new Thread({
			spawnProcess(["~/libexec/i3-mkconfig".expandTilde, "i3-msg", "reload"], stdin, stderr, stderr).wait();
		}).start();

		icon.separator = block.full_text.length == 0;
		send();
	}
}

void main()
{
	conn = new I3Connection();
	conn.clickHandler = toDelegate(&Block.clickHandler);

	try
	{
		// System log
		// new ProcessBlock(["journalctl", "--follow"]);

		// Current window title
		new ProcessBlock(["~/libexec/window-title-follow".expandTilde], (click) {
				switch (click.button)
				{
					case 1: spawnProcess(["~/libexec/x".expandTilde, "rofi", "-show", "window"]).wait(); break;
					case 4: spawnProcess(["i3-msg", "workspace", "prev_on_output"], stdin, File(nullFileName, "w")).wait(); break;
					case 5: spawnProcess(["i3-msg", "workspace", "next_on_output"], stdin, File(nullFileName, "w")).wait(); break;
					default: break;
				}
			});

		version(HOST_n910f)
			{}
		else
		{
			// Current playing track
			new MpdBlock();

			// Time tracking
			new WorkBlock();

			// Volume
			new VolumeBlock();

			// Brightness
			new BrightnessBlock();
		}

		// Battery
		version (HOST_vaio)
			new BatteryBlock("/org/freedesktop/UPower/devices/battery_BAT1");
		version (HOST_t580)
		{
			new BatteryBlock("/org/freedesktop/UPower/devices/battery_BAT0");
			new BatteryBlock("/org/freedesktop/UPower/devices/battery_BAT1");
		}
		version (HOST_mix4)
			new BatteryBlock("/org/freedesktop/UPower/devices/battery_BAT0");
		version (HOST_home)
			new BatteryBlock("/org/freedesktop/UPower/devices/ups_hiddev*");

		// Load
		new LoadBlock();

		// System status
		new SystemStatusBlock();

		// UTC time
		new UtcTimeBlock();

		// Local time
		auto tzFile = expandTilde("~/.config/tz");
		if (tzFile.exists)
			new TzTimeBlock(PosixTimeZone.getTimeZone(readText(tzFile).strip()));

		socketManager.loop();
	}
	catch (Throwable e)
	{
		std.file.write("statusbar-error.txt", e.toString());
		throw e;
	}
}
