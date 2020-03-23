/**
   Parse the output of e.g. `tcpdump -v -n` and display a per-second
   summary of active connections.
   Infer packet loss from missed packet IDs.
   (Written to help troubleshoot problems with my home LAN)
 */

module tcpdump_analyze;

import ae.utils.regex;

import std.math;
import std.regex;
import std.stdio;
import std.string;

void flush(string ts)
{
	writef("[%s]", ts);
	foreach (addressPair, ids; conversations)
	{
		// Make linear for overflows
		uint offset, duplicates;
		foreach (i, ref id1; ids)
		{
			if (!i)
				continue;
			auto id0 = ids[i-1];
			if (id0 == id1)
				duplicates++;
			id1 += offset;

			if (abs(int(id0) - int(id1)) >
				abs(int(id0) - int(id1 + 0x10000)))
			{
				id1 += 0x10000;
				offset += 0x10000;
			}
		}

		auto idRange = 1 + ids[$-1] - ids[0];
		writef(" %s: %4d packets, %4d range, %5.1f%% coverage",
			addressPair, ids.length, idRange, 100. * ids.length / idRange,
		);
		if (duplicates)
			writef(", %4d duplicates", duplicates);
	}
	writeln();
	conversations = null;
}

uint[][string] conversations;

void main()
{
	string lastTimestamp;

	string s;
	ushort lastID;
	while ((s = readln()) !is null)
	{
		s = s.chomp();
		if (s.matchCaptures(re!`^(..:..:..)\....... [^ ]+ \(tos 0x.., ttl \d+, id (\d+), offset \d+, flags \[[^\[\]]+\], proto [^ ]+ \(\d+\), length \d+\)$`,
				(string timestamp, ushort id)
				{
					if (timestamp != lastTimestamp)
					{
						if (lastTimestamp)
							flush(lastTimestamp);
						lastTimestamp = timestamp;
					}
					lastID = id;
				}))
			continue;
		if (s.matchCaptures(re!`^    ([^ ]+ > [^ ]+): [^ ]+, length \d+$`,
				(string addressPair)
				{
					conversations[addressPair] ~= lastID;
				}))
			continue;
		writeln("Unknown line: " ~ s);
	}
	if (conversations)
		flush(lastTimestamp);
}
