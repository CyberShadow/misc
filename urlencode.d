#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/// URL encode stdin to stdout.

import std.stdio;
import std.ascii;
import std.typecons;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text;

void urlEncodeFile(ref File f, ref File o, bool all, string delim)
{
	void doChar(char c)
	{
		if (!all && isAlphaNum(c))
			o.rawWrite((&c)[0..1]);
		else
		{
			char[3] x;
			x[0] = '%';
			static const HEX = "0123456789ABCDEF";
			x[1] = HEX[cast(ubyte)c >> 4];
			x[2] = HEX[cast(ubyte)c & 15];
			o.rawWrite(x[]);
		}
	}

	while (!f.eof)
	{
		if (delim)
		{
			foreach (line; f.byLine(No.keepTerminator, delim))
			{
				foreach (char c; line)
					doChar(c);
				o.rawWrite(delim);
			}
		}
		else
		{
			char c;
			if (f.rawRead((&c)[0..1]).length)
				doChar(c);
		}
	}
}

void urlEncode(bool all, string delim = null)
{
	urlEncodeFile(stdin, stdout, all, delim);
}

mixin main!(funopt!urlEncode);
