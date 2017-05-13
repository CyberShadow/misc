import std.stdio;
import std.ascii;

import ae.utils.text;

void urlEncode(ref File f, ref File o)
{
	while (!f.eof)
	{
		char c;
		if (f.rawRead((&c)[0..1]))
		{
			if (isAlphaNum(c))
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

void main()
{
	urlEncode(stdin, stdout);
}
