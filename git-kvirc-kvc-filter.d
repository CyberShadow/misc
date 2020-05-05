/**
   Git filter for KVIrc *.kvc files.
*/

module git_kvirc_kvc_filter;

import std.algorithm.searching;
import std.algorithm.sorting;
import std.ascii;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.range;
import std.regex;
import std.stdio : stdin, File, stdout;
import std.string;

import ae.sys.cmd;
import ae.sys.file;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.json;
import ae.utils.main;
import ae.utils.regex;

version (all)
{
	private enum bool isSafeCopyable(T) = is(typeof(() @safe { union U { T x; } T *x; auto u = U(*x); }));

	private struct AA { void* impl; }
	extern(C) private void* _aaGetX(AA* paa, const TypeInfo_AssociativeArray ti, const size_t valsz, const scope void* pkey, out bool found) pure nothrow;

	ref V refUpdate(K, V, C, U)(ref V[K] aa, K key, scope C create, scope U update)
	if (is(typeof(create()) : V) && (is(typeof(update(aa[K.init])) : V) || is(typeof(update(aa[K.init])) == void)))
	{
		bool found;
		// if key is @safe-ly copyable, `update` may infer @safe
		static if (isSafeCopyable!K)
		{
			auto p = () @trusted
			{
				return cast(V*) _aaGetX(cast(AA*) &aa, typeid(V[K]), V.sizeof, &key, found);
			} ();
		}
		else
		{
			auto p = cast(V*) _aaGetX(cast(AA*) &aa, typeid(V[K]), V.sizeof, &key, found);
		}
		if (!found)
			*p = create();
		else
		{
			static if (is(typeof(update(*p)) == void))
				update(*p);
			else
				*p = update(*p);
		}
		return *p;
	}
}

struct Order(T)
{
	T[] values;
	size_t[T] lookup;
	bool[size_t][size_t] order; // order[a][b] = a > b

	alias JSONData = T[2][];
	JSONData jsonData;

	void load(string fileName)
	{
		this = typeof(this).init;

		if (!fileName.exists)
			return;

		jsonData = fileName.readText.jsonParse!JSONData;
		foreach (pair; jsonData)
		{
			auto ltIndex = getIndex(pair[0]);
			auto gtIndex = getIndex(pair[1]);
			assert(ltIndex != gtIndex);
			order.require(ltIndex, null).update(gtIndex, () => false, (ref bool dir) { enforce(dir == false, "Order conflict"); });
			order.require(gtIndex, null).update(ltIndex, () => true , (ref bool dir) { enforce(dir == true , "Order conflict"); });
		}
	}

	void save(string fileName)
	{
		jsonData.sort();
		jsonData.toPrettyJson.toFile(fileName);
	}

	private size_t getIndex(T value)
	{
		size_t index;
		lookup.update(
			value,
			{
				index = values.length;
				values ~= value;
				return index;
			},
			(ref size_t oldIndex)
			{
				index = oldIndex;
			});
		return index;
	}

	void add(T lt, T gt)
	{
		auto ltIndex = getIndex(lt);
		auto gtIndex = getIndex(gt);
		assert(ltIndex != gtIndex);

		int result;
		try
			result = cmp(ltIndex, gtIndex);
		catch (Exception e)
		{
			// unordered
			order.require(ltIndex, null).update(gtIndex, () => false, (ref bool dir) { enforce(dir == false, "Order conflict"); });
			order.require(gtIndex, null).update(ltIndex, () => true , (ref bool dir) { enforce(dir == true , "Order conflict"); });
			jsonData ~= [lt, gt];
			return;
		}
		// check existing order
		enforce(result < 0, "Order conflict");
	}

	int cmp(T a, T b)
	{
		return cmp(getIndex(a), getIndex(b));
	}

	private int cmp(size_t aIndex, size_t bIndex)
	{
		if (aIndex == bIndex)
			return 0;
		// auto aOrder = order.get(aIndex);

		static bool[] visited;
		if (visited.length < values.length)
			visited.length = values.length;

		foreach (dir; only(false, true))
		{
			visited[] = false;

			bool visit(size_t i)
			{
				if (visited[i])
					return false;
				visited[i] = true;

				auto iOrder = order.get(i, /*(bool[size_t]).init.nonNull*/null);
				if (iOrder.get(bIndex, !dir) == dir)
					return true;
				foreach (j, ijDir; iOrder)
					if (ijDir == dir)
						if (visit(j))
						{
							//iOrder[bIndex] = dir;
							order[i][bIndex] = dir;
							order[bIndex][i] = !dir;
							return true;
						}
				return false;
			}

			if (visit(aIndex))
				return dir ? 1 : -1;
		}
		throw new Exception("Don't know the order of " ~ text([values[aIndex], values[bIndex]]));
	}
}

unittest
{
	Order!string o;
	o.add("alpha", "beta");
	assert(o.cmp("alpha", "beta") < 0);
	assert(o.cmp("beta", "alpha") > 0);
	o.add("beta", "gamma");
	assert(o.cmp("alpha", "gamma") < 0);
	assert(o.cmp("gamma", "alpha") > 0);
	o.add("beta", "delta");
	assertThrown(o.cmp("gamma", "delta"));
	assertThrown(o.cmp("delta", "gamma"));
}

Order!string stringOrder;

ulong[] toCleanComparable(string s)
{
	ulong[] result;
	foreach (char c; s)
		if (isDigit(c))
			if (result.length && result[$-1] >= 0x100)
				result[$-1] = 0x100 + ((result[$-1] - 0x100) * 10 + (c - '0'));
			else
				result ~= 0x100 + (c - '0');
		else
			result ~= ubyte(c);
	return result;
}

struct KVC
{
	bool clean;
	string[string][string] data;

	private enum header = "# KVIrc configuration file\n";
	private enum cleanHeader = "# KVIrc configuration file (cleaned by git-kvirc-kvc-filter)\n";

	static KVC read(File f = stdin)
	{
		KVC result;

		void checkOrder(string lt, string gt)
		{
			if (result.clean)
				enforce(lt.toCleanComparable < gt.toCleanComparable,
					"Wrong clean order: " ~ text([lt, gt]));
			else
				stringOrder.add(lt, gt);
		}

		auto fileHeader = f.readln();
		enforce(fileHeader == header || fileHeader == cleanHeader, "Bad header");
		result.clean = fileHeader == cleanHeader;

		string lastSectionName, lastName;
		string[string]* currentSection;
		while (!f.eof)
		{
			auto line = f.readln();
			if (!line)
				continue;
			line = line.chomp("\n");
			if (line[0] == '[')
			{
				enforce(line[$-1] == ']');
				auto sectionName = line[1..$-1];
				currentSection = &result.data.refUpdate(
					sectionName,
					() => null,
					(ref string[string] section) { throw new Exception("Duplicate section: " ~ sectionName); },
				);
				lastName = null;
				if (lastSectionName)
					checkOrder(lastSectionName, sectionName);
				lastSectionName = sectionName;
			}
			else
			{
				auto parts = line.findSplit("=");
				enforce(parts[1].length, "Unknown line in .kvc file: " ~ line);
				auto name = parts[0];
				auto value = parts[2];
				update(
					*currentSection,
					name,
					() => value,
					(ref string oldValue) { throw new Exception("Duplicate value: " ~ lastSectionName ~ "." ~ name); },
				);
				if (lastName)
					checkOrder(lastName, name);
				lastName = name;
			}
		}
		return result;
	}

	void write(bool clean, File f = stdout)
	{
		f.write(clean ? cleanHeader : header);
		string[] kvcSort(string[] input)
		{
			if (clean)
				return input.schwartzSort!toCleanComparable.release();
			else
				return input.sort!((a, b) => stringOrder.cmp(a, b) < 0).release();
		}

		foreach (sectionName; kvcSort(data.keys))
		{
			f.write('[', sectionName, "]\n");
			auto section = data[sectionName];
			foreach (name; kvcSort(section.keys))
				f.write(name, '=', section[name], '\n');
		}
	}
}

void entry(
	string fileName,
	bool clean = false,
	bool smudge = false,
)
{
	// clean: filesystem -> git
	// smudge: git -> filesystem

	enforce(clean != smudge, "Must specify --clean OR --smudge");
	enforce(fileName.extension == ".kvc", "Expected a .kvc file");

	if (fileName.baseName == "colorize.kvc")
	{
		foreach (chunk; stdin.byChunk(4096))
			stdout.rawWrite(chunk);
		return;
	}

	auto stringOrderFileName = "~/.config/private/kvircStringOrder.json".expandTilde;
	stringOrder.load(stringOrderFileName);
	scope(success) stringOrder.save(stringOrderFileName);

	auto kvc = KVC.read();

	if (clean != kvc.clean)
	{
		switch (fileName.baseName)
		{
			case "main.kvc":
				if (clean)
				{
					kvc.data.get("None", null).remove("uintTotalConnectionTime");
					kvc.data.get("Geometry", null).remove("rectFrameGeometry");
					kvc.data.get("Recent", null).remove("stringlistRecentChannels");
					kvc.data.get("Recent", null).remove("stringlistRecentServers");
					kvc.data.get("Recent", null).remove("stringlistRecentNicknames");
					kvc.data.get("Recent", null).remove("stringlistRecentIrcUrls");
				}
				break;
			case "serverdb.kvc":
			{
				auto host = query(["hostname", "-s"]).chomp();
				foreach (sectionName, ref section; kvc.data)
				{
					foreach (name, ref value; section)
						if (name.endsWith("_Pass"))
						{
							if (clean)
								value = value.replaceAll(re!`cybershadow@.*-kvirc`, `cybershadow@HOST-kvirc`);
							else
								value = value.replace(`cybershadow@HOST-kvirc`, `cybershadow@` ~ host ~ `-kvirc`);
						}

					// Swap #_... prefix and #_Id value
					string[string] idMap;
					foreach (name, value; section)
						if (name.endsWith("_Id"))
							idMap[name.findSplit("_")[0]] = value;

					string[string] newSection;
					foreach (name, value; section)
					{
						auto parts = name.findSplit("_");
						if (parts[1].length)
							if (auto id = parts[0] in idMap)
							{
								name = *id ~ "_" ~ parts[2];
								if (parts[2] == "Id")
									value = parts[0];
							}
						newSection[name] = value;
					}
					section = newSection;
				}
				break;
			}
			default:
		}
	}

	kvc.write(clean);
}

mixin main!(funopt!entry);
