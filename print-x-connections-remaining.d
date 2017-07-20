/**
   Estimate the number of free X11 client slots by saturating the
   pool, and counting the number of successful connections.
*/

module print_x_connections_remaining;

import std.stdio;

pragma(lib, "X11");
pragma(lib, "Xss");

import deimos.X11.extensions.scrnsaver;
import deimos.X11.Xlib;

void main()
{
	Display*[] connections;
	while (true)
	{
		Display *dpy = XOpenDisplay(":0");
		if (dpy)
			connections ~= dpy;
		else
			break;
	}

	foreach (dpy; connections)
		XCloseDisplay(dpy);

	writeln();
	writeln(connections.length);
}
