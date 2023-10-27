/**
   Take an image (without an alpha channel), and create an image (with
   an alpha channel) such that each pixel's alpha channel value is
   minimized, and, when viewed over a background of the indicated
   color, the same (blended) color is produced. Effectively this
   converts a single color (e.g. white or black) to alpha.
*/

import std.file;

import ae.sys.file;
import ae.utils.funopt;
import ae.utils.graphics.color;
import ae.utils.graphics.im_convert;
import ae.utils.graphics.image;
import ae.utils.main;

Image!RGBA makeAlpha(I)(ref I p, RGB bg)
{
	auto result = Image!RGBA(p.w, p.h);
	foreach (y; 0 .. p.h)
		foreach (x; 0 .. p.w)
		{
			static void calcAlpha(ubyte x, ubyte y, out ubyte c, out int a)
			{
				a = 255+x-y;
				c = a==0 ? 0 : cast(ubyte)(255*x / a);
			}

			auto c = p[x, y];
			if (RGB(c.r, c.g, c.b) == bg)
			{
				result[x, y] = RGBA(bg.tupleof, 0);
				continue;
			}

			foreach (a; 0 .. 256)
			{
				/*
				  c = (fg * a) + (bg * (1-a))
				  c - (bg * (1-a)) = fg * a
				  (c - (bg * (1-a))) / a = fg
				*/
				double r = (c.r/255.0 - (bg.r/255.0 * (1-(a/255.0)))) / (a/255.0);
				double g = (c.g/255.0 - (bg.g/255.0 * (1-(a/255.0)))) / (a/255.0);
				double b = (c.b/255.0 - (bg.b/255.0 * (1-(a/255.0)))) / (a/255.0);
				if (r < 0 || r > 1 || g < 0 || g > 1 || b < 0 || b > 1)
					continue;
				result[x, y] = RGBA(
					cast(ubyte)(r * 255.0),
					cast(ubyte)(g * 255.0),
					cast(ubyte)(b * 255.0),
					cast(ubyte)a
				);
				break;
			}
		}
	return result;
}

void program(string inputImageFileName, string outputImageFileName, string backgroundColor = "FFFFFF")
{
	auto p = inputImageFileName.read().parseViaIMConvert!BGR.colorMap!(c => RGB(c.r, c.g, c.b));
	auto col = RGB.fromHex(backgroundColor);
	makeAlpha(p, col).toPNG.toFile(outputImageFileName);
}

mixin main!(funopt!program);
