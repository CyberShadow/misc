#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Create a video file suitable for observing vertical sync
   discrepancies between MST panels for monitors using DisplayPort MST
   to display themselves as several such panels.
*/

import std.algorithm.comparison;
import std.range;

import ae.utils.graphics.color;
import ae.utils.graphics.draw;
import ae.utils.graphics.ffmpeg;
import ae.utils.graphics.image;

enum w = 1920;
enum h = 1080;
enum strip = 20;

enum period = strip * 2;
enum speed = 2;

void main()
{
	auto v = VideoOutputStream("mst_sync_test.mp4", null, ["-framerate", "60"]);

	alias Color = BGR;
	enum fg = Color.white;
	enum bg = Color.black;
	auto i = Image!Color(w, h);

	enum size = max(w, h);
	foreach (phase; iota(0, period, speed))
	{
		i.clear(bg);
		foreach (pos; iota(-size, size, period))
		{
			auto d = phase + pos;
			i.fillPoly([Coord(d, 0), Coord(d + size, size), Coord(d + size + strip, size), Coord(d + strip, 0)], fg);
		}
		v.put(i);
	}
}
