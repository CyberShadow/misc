#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3461"
 dependency "ae:x11" version="==0.0.3461"
+/

/// Creates a white window.
/// Usable as a poor-man's ring-light.

import std.algorithm.iteration;
import std.array;

import ae.net.asockets;
import ae.net.x11;
import ae.utils.array;
import ae.utils.promise;

// Note: this program is almost identical to the ae X11 demo.

void main()
{
	auto x11 = new X11Client();

	Atom[string] atoms;
	Promise!Atom getAtom(string name)
	{
		auto p = new Promise!Atom;
		if (auto patom = name in atoms)
			p.fulfill(*patom);
		else
			x11.sendInternAtom(false, name)
				.dmd21804workaround
 				.then((result) {
					atoms[name] = result.atom;
					p.fulfill(result.atom);
				});
		return p;
	}

	Window wid;
	auto gc = new Promise!GContext;

	x11.handleConnect = {
		wid = x11.newRID();

		WindowAttributes windowAttributes;
		windowAttributes.eventMask = ExposureMask;
		x11.sendCreateWindow(
			0,
			wid,
			x11.roots[0].root.windowId,
			0, 0,
			256, 256,
			0,
			InputOutput,
			x11.roots[0].root.rootVisualID,
			windowAttributes,
		);
		x11.sendMapWindow(wid);

		auto gcRID = x11.newRID();
		GCAttributes gcAttributes;
		gcAttributes.foreground = x11.roots[0].root.whitePixel;
		gcAttributes.background = x11.roots[0].root.whitePixel;
		x11.sendCreateGC(
			gcRID, wid,
			gcAttributes,
		);
		gc.fulfill(gcRID);

		["WM_PROTOCOLS", "WM_DELETE_WINDOW", "ATOM"]
			.map!getAtom
			.array
			.all
			.then((result) {
				x11.sendChangeProperty(
					PropModeReplace,
					wid,
					atoms["WM_PROTOCOLS"], atoms["ATOM"],
					32,
					[atoms["WM_DELETE_WINDOW"]].asBytes,
				);
			});
	};

	x11.handleExpose = (event) {
		if (event.window == wid)
		{
			gc.then((gcRID) {
				x11.sendPolyFillRectangle(wid, gcRID, [xRectangle(0, 0, ushort.max, ushort.max)]);
			});
		}
	};

	x11.handleMappingNotify = (event) { /* ignore */ };

	x11.handleClientMessage = (event) {
		if (event.type == atoms["WM_PROTOCOLS"])
		{
			auto messageAtoms = event.bytes.as!(Atom[]);
			if (messageAtoms[0] == atoms["WM_DELETE_WINDOW"])
				x11.conn.disconnect();
		}
	};

	socketManager.loop();
}
