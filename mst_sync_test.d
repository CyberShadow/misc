import ae.utils.graphics.color;
import ae.utils.graphics.draw;
import ae.utils.graphics.ffmpeg;
import ae.utils.graphics.image;

enum w = 1920;
enum h = 1080;
enum stripH = 20;

void main()
{
	auto v = VideoOutputStream("mst_sync_test.mp4", null, ["-framerate", "60"]);

	alias Color = BGR;
	enum fg = Color.white;
	enum bg = Color.black;
	auto i = Image!Color(w, h);

	i.clear(bg);
	i.fillRect(0, 0, w, stripH, fg);
	foreach (y; 0 .. h)
	{
		i.hline(0, w, y, bg);
		i.hline(0, w, (y + stripH) % h, fg);
		v.put(i);
	}
}
