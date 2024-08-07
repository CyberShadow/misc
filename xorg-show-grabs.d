#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
 dependency "libx11" version="==0.0.1"
+/

/**
   Decode grabs from X11 log file, as generated by
   `xdotool key XF86LogGrabInfo`.
*/

module xorg_show_grabs;

import std.algorithm;
import std.conv;
import std.exception;
import std.stdio;

import ae.utils.array;
import ae.utils.regex;

void main()
{
	string[] results;

	string currentClient;
	bool currentGrab;
	int currentKey, currentMod;
	
	auto f = File("/var/log/Xorg.0.log");
	foreach (l; f.byLine())
	{
		auto line = l.findSplit("] ")[2];
		if (!line.length)
			continue;

		if (line == "Printing all currently registered grabs")
			results = null;
		else
		if (line.skipOver("  Printing all registered grabs of client pid "))
			currentClient = line.idup;
		else
		if (line.skipOver("  grab "))
		{
			currentGrab = false;
			line.skipUntil(' ');
			if (!line.startsWith("(core), type 'KeyPress' on window "))
				continue;
			currentGrab = true;
		}
		else
		if (line.skipOver("    device "))
		{
			if (line != "'Virtual core keyboard' (3), modifierDevice 'Virtual core keyboard' (3)")
				currentGrab = false;
		}
		else
		if (line.skipOver("    detail "))
		{
			currentKey = line.skipUntil(' ').to!int;
			if (!line.skipOver("(mask 0), modifiersDetail "))
				continue;
			currentMod = line.skipUntil(' ').to!int;
		}
		else
		if (line.skipOver("    owner-events "))
		{
			if (currentGrab)
			{
				results ~= currentClient ~ " - " ~ xModToString(currentMod)~xKeyToString(currentKey);
				currentGrab = false;
			}
		}
	}
	results.each!writeln;
}


pragma(lib, "X11");

import deimos.X11.X;
import deimos.X11.Xlib;

extern(C) KeySym XkbKeycodeToKeysym(Display *dpy, KeyCode kc, uint group, uint level);

string xKeyToString(int key)
{
	static Display *dpy = null;
	if (!dpy)
		dpy = enforce(XOpenDisplay(":0"), "Can't open display!");
	
	KeySym ks = XkbKeycodeToKeysym(dpy, cast(ubyte)key, 0, 0);
        
	return XKeysymToString(ks).to!string();
}

string xModToString(int mod)
{
	//							1			2			4			8			0x10		0x20		0x40		0x80
	//const string[] names = [	"Shift", 	"Lock", 	"Control", 	"Mod1", 	"Mod2", 	"Mod3", 	"Mod4", 	"Mod5"];
	const string[] names = [	"Shift", 	"Lock", 	"Control", 	"Alt" , 	"Mod2", 	"Mod3", 	"Win" , 	"Mod5"];
	string result;
	foreach (i, name; names)
		if ((1<<i) & mod)
			result ~= name ~ "+";
	return result;
}
