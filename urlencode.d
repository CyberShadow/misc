/// URL encode stdin to stdout.

import std.stdio;
import std.ascii;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text;

void urlEncodeFile(ref File f, ref File o, bool all)
{
	while (!f.eof)
	{
		char c;
		if (f.rawRead((&c)[0..1]))
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
	}
}

void urlEncode(bool all)
{
	urlEncodeFile(stdin, stdout, all);
}

mixin main!(funopt!urlEncode);
