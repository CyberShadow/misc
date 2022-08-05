// General-purpose UInput event filter.

module input_filter;

import std.process;
import std.stdio : stderr;
import std.string;

import ae.net.asockets;

import uinput_filter.client;
import uinput_filter.common;

import mylib.linux.input_event_codes;

class Client : UInputFilterClient
{
	override void processPacket(ref Packet p)
	{
		if (p.device == DeviceType.headset && p.ev.type == EV_KEY)
		{
			stderr.writeln("Got headset EV_KEY: ", p.ev);
			switch (p.ev.code)
			{
				case KEY_PLAYCD:
					// Sent automatically when hanging up a call.
					// Annoying, because it's sent indiscriminately if
					// something was playing when the call started.
					// Convert to KEY_PAUSECD, so that the matching
					// KEY_PAUSECD sent at the start of the call
					// causes us to toggle back to the pre-call state.
					p.ev.code = KEY_PAUSECD;
					goto case KEY_PAUSECD;

				case KEY_PAUSECD:
				case KEY_NEXTSONG:
				case KEY_PREVIOUSSONG:
					// Do something differently if MPV is focused.
					bool isMpv = execute(["xtitle"]).output.strip.endsWith(" - mpv");
					if (isMpv)
					{
						final switch (p.ev.code)
						{
							case KEY_PAUSECD:
								p.ev.code = KEY_SPACE;
								break;
							case KEY_NEXTSONG:
								p.ev.code = KEY_FASTFORWARD;
								break;
							case KEY_PREVIOUSSONG:
								p.ev.code = KEY_REWIND;
								break;
						}
					}
					break;

				default:
					stderr.writeln("Unknown key from headset: ", p.ev.code);
			}
		}

		send(p);
	}
}

void main()
{
	new Client();
	socketManager.loop();
}
