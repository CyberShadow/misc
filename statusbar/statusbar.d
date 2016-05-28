import std.algorithm;
import std.conv;
import std.datetime;
import std.file;

import ae.net.asockets;
import ae.sys.timing;
import ae.utils.meta;
import ae.utils.meta.args;
import ae.utils.time.format;

import fontawesome;
import i3;
import i3conn;
import pulse;

void main()
{
	auto i3 = new I3Connection();

	auto localTz = PosixTimeZone.getTimeZone("Europe/Chisinau");

	enum Block
	{
		volumeIcon,
		volume,
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

		blocks[Block.load].full_text = readText("/proc/loadavg").splitter(" ").front;

		// Time

		auto local = now;
		local.timezone = localTz;
		blocks[Block.timeLocal].full_text = local.formatTime!`D Y-m-d H:i:s O`;
		blocks[Block.timeLocal].background = "#000040";

		blocks[Block.timeUTC].full_text = now.formatTime!`D Y-m-d H:i:s \U\T\C`;
		blocks[Block.timeUTC].background = "#004040";

		// Send!

		i3.send(blocks[]);
		setTimeout(&updateTime, 1.seconds - now.fracSecs);
	}
	updateTime();

	void updatePulse()
	{
		auto volume = getVolume();
		dchar icon = FontAwesome.fa_volume_off;
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

	socketManager.loop();
}
