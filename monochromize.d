#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/// Read a 32-bit BMP image.
/// Produce a monochrome PNG image.
/// Does not perform dithering.

module monochromize;

import std.algorithm.sorting;
import std.stdio;

import ae.sys.file;
import ae.utils.graphics.color;
import ae.utils.graphics.gamma;
import ae.utils.graphics.image;

void main()
{
	auto data = readFile(stdin);
	auto bmp = parseBMP!BGRA(data);
	auto gamma = gammaRamp!(ushort, ubyte, ColorSpace.sRGB);

	double getBrightness(BGRA c)
	{
		auto l = gamma.pix2lum(c);
		return
			0.2126 * l.r / typeof(l.r).max +
			0.7152 * l.g / typeof(l.g).max +
			0.0722 * l.b / typeof(l.b).max ;
	}

	double threshold;
	if (false) // automatic level selection
	{
		auto brightnesses = new double[bmp.w * bmp.h];
		size_t p = 0;
		foreach (y; 0 .. bmp.h)
			foreach (x; 0 .. bmp.w)
			{
				auto c = bmp[x, y];
				auto brightness = getBrightness(c);
				brightnesses[p++] = brightness;
			}

		brightnesses.sort();
		threshold = brightnesses[$ / 2]; // median
	}
	else
		threshold = 0.5;

	auto mono = Image!(bool, OneBitStorageBE)(bmp.w, bmp.h);
	foreach (y; 0 .. bmp.h)
		foreach (x; 0 .. bmp.w)
		{
			auto c = bmp[x, y];
			auto brightness = getBrightness(c);
			mono[x, y] = brightness >= threshold;
		}

	stdout.rawWrite(mono.toPNG);
}
