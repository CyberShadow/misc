import std.algorithm;
import std.exception;
import std.file;
import std.string;

void loadConfig(string fn, ref string[string] values, ref bool[string] allValues)
{
	foreach (line; fn.readText().splitLines())
	{
		if (!line.length || line[0] == '#')
			continue;
		auto parts = line.findSplit("=");
		enforce(parts[1].length, "Bad line: " ~ line);
		values[parts[0]] = parts[2];
		allValues[parts[0]] = true;
	}
}

