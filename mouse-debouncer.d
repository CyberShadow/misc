/**
 * Work around a hardware fault in my Logitech G700 mouse which causes
 * it to sporadically perceive the left mouse button as released for
 * short periods of time, when it is actually fully pressed.
 */

module mouse_debouncer;

import core.time;

import ae.net.asockets;
import ae.sys.timing;

import uinput_filter.client;
import uinput_filter.common;

import mylib.linux.input_event_codes;

debug(verbose) import std.stdio;

private:

final class MyFilterClient : UInputFilterClient
{
	// Higher values result in some double clicks not being recognized
	// (and instead seen as a single long click).
	enum threshold = 50.msecs;

	TimerTask task;
	Packet pendingPacket;

	this()
	{
		task = new TimerTask(threshold, &onTimer);
	}

	long last;

	override void processPacket(ref Packet p)
	{
		auto time = p.ev.time.tv_sec * 1_000_000L + p.ev.time.tv_usec;
		if (p.ev.type == EV_KEY && p.ev.code == BTN_LEFT)
		{
			debug(verbose) writefln("[%d.%06d] %s %s", p.ev.time.tupleof, p.ev.code, p.ev.value);
			if (p.ev.value == 0)
			{
				last = time;
				pendingPacket = p;
				mainTimer.add(task);
				return;
			}
			else
			{
				debug(verbose) writeln(time - last);
				if (task.isWaiting())
				{
					debug(verbose) writeln("Filtered!");
					task.cancel();
					return;
				}
			}
		}

		send(p);
	}

	void onTimer(Timer timer, TimerTask task)
	{
		debug(verbose) writeln("Releasing.");
		auto p = pendingPacket;
		send(p);

		p.ev.type = EV_SYN;
		p.ev.code = SYN_REPORT;
		p.ev.value = 0;
		send(p);
	}
}

void main()
{
	auto c = new MyFilterClient();
	socketManager.loop();
}
