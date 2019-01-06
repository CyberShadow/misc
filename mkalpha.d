/**
   Take two images of the same possibly-translucent object:
   first on a black background, second on a white background.
   Create a third PNG image with transparency,
   so that overlaying it on a black or white canvas
   will produce the first / second image correspondingly.
*/

import std.file;

import ae.sys.file;
import ae.utils.graphics.color;
import ae.utils.graphics.im_convert;
import ae.utils.graphics.image;

Image!RGBA makeAlpha(I)(ref I p0, ref I p1)
{
	auto result = Image!RGBA(p0.w, p0.h);
	foreach (y; 0..p0.h)
		foreach (x; 0..p0.w)
		{
			static void calcAlpha(ubyte x, ubyte y, out ubyte c, out int a)
			{
				a = 255+x-y;
				c = a==0 ? 0 : cast(ubyte)(255*x / a);
			}

			auto c0 = p0[x, y];
			auto c1 = p1[x, y];
			RGBA c;
			int a1, a2, a3;
			calcAlpha(c0.r, c1.r, c.r, a1);
			calcAlpha(c0.g, c1.g, c.g, a2);
			calcAlpha(c0.b, c1.b, c.b, a3);
			c.a = cast(ubyte)((a1 + a2 + a3) / 3);
			result[x, y] = c;
		}
	return result;
}

void main(string[] args)
{
	auto p0 = args[1].read().parseViaIMConvert!BGR;
	auto p1 = args[2].read().parseViaIMConvert!BGR;
	makeAlpha(
		p0,
		p1,
	).toPNG.toFile(args[3]);
}
