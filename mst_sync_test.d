import std.range;

import ae.utils.graphics.color;
import ae.utils.graphics.draw;
import ae.utils.graphics.ffmpeg;
import ae.utils.graphics.image;

enum w = 1920;
enum h = 1080;
enum stripH = 20;

enum period = stripH * 2;

void main()
{
	auto v = VideoOutputStream("mst_sync_test.mp4", null, ["-framerate", "60"]);

	alias Color = BGR;
	enum fg = Color.white;
	enum bg = Color.black;
	auto i = Image!Color(w, h);

	i.clear(bg);
	foreach (y; iota(0, h, period))
		i.fillRect(0, y, w, y + stripH, fg);
	foreach (phase; 0 .. period)
	{
		foreach (y; iota(0, h, period))
		{
			i.hline(0, w,  phase + y              , bg);
			i.hline(0, w, (phase + y + stripH) % h, fg);
		}
		v.put(i);
	}
}
