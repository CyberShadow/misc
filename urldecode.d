/// URL decode stdin to stdout.

import std.stdio;

import ae.utils.text;

void urlDecode(ref File f, ref File o)
{
	while (!f.eof)
	{
		char c;
		f.rawRead((&c)[0..1]);
		if (c == '%')
		{
			char[2] x;
			f.rawRead(x[]);
			c = cast(char)fromHex!ubyte(x[]);
		}
		o.rawWrite((&c)[0..1]);
	}
}

void main()
{
	urlDecode(stdin, stdout);
}
