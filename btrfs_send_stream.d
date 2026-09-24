/// Parser for btrfs send streams, which attributes the file data they
/// carry to the paths it ends up at in the received subvolume.
module btrfs_send_stream;

import std.algorithm.mutation : copy;
import std.array : split;
import std.bitmanip : littleEndianToNative;
import std.encoding : isValid, sanitize;
import std.exception : enforce;
import std.format : format;

import ae.utils.json : JSONName, JSONOptional;

/// Data and command totals for a path and everything below it.
struct DeltaTree
{
	/// Bytes of file data written, as the logical (uncompressed) length.
	ulong size;
	/// Number of stream commands which operated on this path.
	ulong commands;
	@JSONOptional DeltaTree[string] children; ///
}

/// Describes the btrfs send stream which transferred a snapshot.
struct Delta
{
	/// Name of the snapshot the stream was relative to,
	/// or null if the stream contained the whole snapshot.
	string parent;
	/// Total size of the send stream, including headers.
	ulong streamBytes;
	/// Bytes of file data written (sum of the tree's leaf sizes,
	/// plus data written to files deleted later in the same stream).
	ulong dataBytes;
	/// Total number of stream commands.
	ulong commands;
	/// Per-path totals, keyed by the paths' final names.
	DeltaTree tree;
}

/// Contents of the metadata file written next to a received snapshot.
struct SnapshotMetadata
{
	@JSONName("version") uint formatVersion = 1; ///
	Delta delta; ///
}

/// Push parser: feed the stream with `put`, then call `finish`.
struct SendStreamParser
{
	private ubyte[] buf; // received but not yet parsed
	private uint streamVersion; // 0 until the header is parsed
	private bool ended; // END command seen
	private bool isFull; // stream starts with SUBVOL, not SNAPSHOT
	private ulong streamBytes, dataBytes, commands;
	private Node root;

	/// Feed the next chunk of the stream.
	void put(const(ubyte)[] data)
	{
		streamBytes += data.length;
		buf ~= data;
		auto pos = parse(buf);
		auto rest = buf.length - pos;
		copy(buf[pos .. $], buf[0 .. rest]);
		buf.length = rest;
		buf.assumeSafeAppend();
	}

	/// Verify that the stream was complete, and return its description.
	/// `parent` is the name of the snapshot the stream was relative to.
	Delta finish(string parent)
	{
		enforce(streamVersion, "Truncated send stream (no header)");
		enforce(ended, "Truncated send stream (no end command)");
		enforce(buf.length == 0, "Truncated send stream (partial command)");
		enforce(isFull == !parent,
			isFull ? "Send stream is whole, but a parent was specified" : "Send stream is incremental, but no parent was specified");
		return Delta(parent, streamBytes, dataBytes, commands, toTree(rootNode));
	}

private:
	static final class Node
	{
		ulong size, commands;
		Node[string] children;
	}

	@property Node rootNode()
	{
		if (!root)
			root = new Node;
		return root;
	}

	enum ubyte[13] magic = cast(ubyte[13])"btrfs-stream\0";
	enum headerLength = magic.length + 4;
	enum commandHeaderLength = 4 + 2 + 4; // len, cmd, crc
	enum maxVersion = 3;

	// Command and attribute numbers, from linux/fs/btrfs/send.h.
	enum Cmd : ushort
	{
		subvol = 1, snapshot = 2,
		mkfile = 3, mkdir = 4, mknod = 5, mkfifo = 6, mksock = 7, symlink = 8,
		rename = 9, link = 10, unlink = 11, rmdir = 12,
		setXattr = 13, removeXattr = 14,
		write = 15, clone = 16,
		truncate = 17, chmod = 18, chown = 19, utimes = 20,
		end = 21, updateExtent = 22,
		// v2
		fallocate = 23, fileattr = 24, encodedWrite = 25,
		// v3
		enableVerity = 26,
	}
	static immutable ushort[maxVersion + 1] maxCmd = [0, 22, 25, 26];

	enum Attr : ushort
	{
		size = 4,
		path = 15, pathTo = 16,
		data = 19,
		unencodedFileLen = 27,
	}
	static immutable ushort[maxVersion + 1] maxAttr = [0, 24, 31, 35];

	static T le(T)(const(ubyte)[] b)
	{
		enforce(b.length == T.sizeof, "Invalid send stream attribute length");
		return littleEndianToNative!T(b[0 .. T.sizeof]);
	}

	/// Parse as many complete commands as available, return number of bytes consumed.
	size_t parse(const(ubyte)[] b)
	{
		size_t pos;
		if (!streamVersion)
		{
			if (b.length < headerLength)
				return 0;
			enforce(b[0 .. magic.length] == magic[], "Not a btrfs send stream");
			auto v = le!uint(b[magic.length .. headerLength]);
			enforce(v >= 1 && v <= maxVersion, "Unsupported send stream version %d".format(v));
			streamVersion = v;
			pos = headerLength;
		}
		while (b.length - pos >= commandHeaderLength)
		{
			enforce(!ended, "Data after the end of the send stream");
			auto len = le!uint(b[pos .. pos + 4]);
			auto cmd = le!ushort(b[pos + 4 .. pos + 6]);
			if (b.length - pos - commandHeaderLength < len)
				break;
			pos += commandHeaderLength;
			command(cmd, b[pos .. pos + len]);
			pos += len;
		}
		return pos;
	}

	void command(ushort cmd, const(ubyte)[] body)
	{
		enforce(cmd >= 1 && cmd <= maxCmd[streamVersion],
			"Unknown command %d in send stream version %d".format(cmd, streamVersion));
		commands++;
		enforce((commands == 1) == (cmd == Cmd.subvol || cmd == Cmd.snapshot),
			"Send stream must start with, and only with, a subvolume command");

		const(ubyte)[][maxAttr[$ - 1] + 1] attrs;
		bool[attrs.length] present;
		size_t p = 0;
		while (p < body.length)
		{
			enforce(body.length - p >= 2, "Truncated attribute header");
			auto type = le!ushort(body[p .. p + 2]);
			enforce(type >= 1 && type <= maxAttr[streamVersion],
				"Unknown attribute %d in send stream version %d".format(type, streamVersion));
			enforce(!present[type], "Duplicate attribute %d".format(type));
			present[type] = true;
			if (streamVersion >= 2 && type == Attr.data)
			{
				// Must be last; length is implicit.
				attrs[type] = body[p + 2 .. $];
				p = body.length;
			}
			else
			{
				enforce(body.length - p >= 4, "Truncated attribute header");
				auto len = le!ushort(body[p + 2 .. p + 4]);
				enforce(body.length - p - 4 >= len, "Truncated attribute");
				attrs[type] = body[p + 4 .. p + 4 + len];
				p += 4 + len;
			}
		}

		const(ubyte)[] attr(Attr type)
		{
			enforce(present[type], "Command %d is missing attribute %d".format(cmd, type));
			return attrs[type];
		}

		void addData(ulong len)
		{
			dataBytes += len;
			auto node = getNode(attr(Attr.path));
			node.size += len;
			node.commands++;
		}

		switch (cmd)
		{
			case Cmd.subvol:
			case Cmd.snapshot:
				isFull = cmd == Cmd.subvol;
				break;
			case Cmd.end:
				ended = true;
				break;
			case Cmd.rename:
				move(attr(Attr.path), attr(Attr.pathTo));
				getNode(attr(Attr.pathTo)).commands++;
				break;
			case Cmd.unlink:
			case Cmd.rmdir:
				detach(attr(Attr.path));
				break;
			case Cmd.write:
				addData(attr(Attr.data).length);
				break;
			case Cmd.encodedWrite:
				addData(le!ulong(attr(Attr.unencodedFileLen)));
				break;
			case Cmd.updateExtent: // sent instead of write with --no-data
				addData(le!ulong(attr(Attr.size)));
				break;
			default:
				getNode(attr(Attr.path)).commands++;
				break;
		}
	}

	/// Paths are arbitrary bytes, but must be valid UTF-8 for JSON;
	/// invalid sequences are replaced with U+FFFD.
	static const(char)[][] toSegments(const(ubyte)[] path)
	{
		auto s = cast(const(char)[])path;
		if (!s.isValid)
			s = s.idup.sanitize;
		return s.length ? s.split("/") : null;
	}

	Node getNode(const(ubyte)[] path)
	{
		return getNode(toSegments(path));
	}

	Node getNode(const(char)[][] segments)
	{
		auto node = rootNode;
		foreach (segment; segments)
		{
			auto next = segment in node.children;
			if (next)
				node = *next;
			else
				node = node.children[segment.idup] = new Node;
		}
		return node;
	}

	/// Detach and return the node at `path`, or null if it doesn't exist.
	Node detach(const(ubyte)[] path)
	{
		auto segments = toSegments(path);
		enforce(segments.length, "Attempting to detach the root directory");
		auto node = rootNode;
		foreach (segment; segments[0 .. $ - 1])
		{
			auto next = segment in node.children;
			if (!next)
				return null;
			node = *next;
		}
		auto name = segments[$ - 1].idup;
		auto result = node.children.get(name, null);
		node.children.remove(name);
		return result;
	}

	/// Like rename(2): whatever was at `to` is replaced.
	void move(const(ubyte)[] from, const(ubyte)[] to)
	{
		auto node = detach(from);
		detach(to);
		if (!node)
			return;
		auto segments = toSegments(to);
		auto parent = getNode(segments[0 .. $ - 1]);
		parent.children[segments[$ - 1].idup] = node;
	}

	static DeltaTree toTree(Node node)
	{
		auto tree = DeltaTree(node.size, node.commands);
		foreach (name, child; node.children)
		{
			auto childTree = toTree(child);
			tree.size += childTree.size;
			tree.commands += childTree.commands;
			tree.children[name] = childTree;
		}
		return tree;
	}
}

version (unittest)
{
	import std.bitmanip : nativeToLittleEndian;
	import std.exception : assertThrown;

	private ubyte[] tlv(ushort type, const(void)[] value)
	{
		return nativeToLittleEndian(type) ~ nativeToLittleEndian(cast(ushort)value.length) ~ cast(const(ubyte)[])value;
	}

	private ubyte[] cmd(ushort type, const(ubyte)[][] attrs...)
	{
		ubyte[] body;
		foreach (a; attrs)
			body ~= a;
		return nativeToLittleEndian(cast(uint)body.length) ~ nativeToLittleEndian(type) ~ nativeToLittleEndian(0u) ~ body;
	}

	private ubyte[] header(uint streamVersion)
	{
		return cast(ubyte[])"btrfs-stream\0" ~ nativeToLittleEndian(streamVersion);
	}

	private alias P = SendStreamParser;
	private ubyte[] path(const(char)[] s) { return tlv(P.Attr.path, s); }
	private ubyte[] pathTo(const(char)[] s) { return tlv(P.Attr.pathTo, s); }
	private ubyte[] data(size_t n) { return tlv(P.Attr.data, new ubyte[n]); }
	private ubyte[] u64(ushort type, ulong v) { return tlv(type, nativeToLittleEndian(v)); }
	private ubyte[] subvol() { return cmd(P.Cmd.subvol, path("subvol")); }
	private ubyte[] snapshot() { return cmd(P.Cmd.snapshot, path("subvol")); }
	private ubyte[] end() { return cmd(P.Cmd.end); }

	private Delta parseStream(const(ubyte)[] stream, string parent, size_t chunkSize = size_t.max)
	{
		SendStreamParser parser;
		while (stream.length)
		{
			auto n = chunkSize < stream.length ? chunkSize : stream.length;
			parser.put(stream[0 .. n]);
			stream = stream[n .. $];
		}
		return parser.finish(parent);
	}
}

// Whole stream; new files are created under temporary names and renamed.
unittest
{
	auto stream = header(1) ~ subvol ~
		cmd(P.Cmd.mkdir, path("d")) ~
		cmd(P.Cmd.mkfile, path("o257-1-0")) ~
		cmd(P.Cmd.rename, path("o257-1-0"), pathTo("d/f")) ~
		cmd(P.Cmd.write, path("d/f"), data(100)) ~
		cmd(P.Cmd.write, path("d/f"), data(50)) ~
		cmd(P.Cmd.utimes, path("")) ~
		end;
	foreach (chunkSize; [1, 7, size_t.max])
	{
		auto d = parseStream(stream, null, chunkSize);
		assert(d.parent is null);
		assert(d.streamBytes == stream.length);
		assert(d.dataBytes == 150);
		assert(d.commands == 8);
		assert(d.tree.size == 150);
		assert(d.tree.commands == 6);
		assert(d.tree.children.keys == ["d"]);
		assert(d.tree.children["d"].size == 150);
		assert(d.tree.children["d"].commands == 5);
		assert(d.tree.children["d"].children["f"].size == 150);
		assert(d.tree.children["d"].children["f"].commands == 4);
		assert(d.tree.children["d"].children["f"].children is null);
	}
}

// Data written under a directory's temporary name is moved with it.
unittest
{
	auto d = parseStream(header(1) ~ snapshot ~
		cmd(P.Cmd.mkdir, path("o300-5-0")) ~
		cmd(P.Cmd.write, path("o300-5-0/x"), data(10)) ~
		cmd(P.Cmd.rename, path("o300-5-0"), pathTo("a/new")) ~
		end, "@subvol-1");
	assert(d.parent == "@subvol-1");
	assert(d.tree.children.keys == ["a"]);
	assert(d.tree.children["a"].children["new"].children["x"].size == 10);
}

// Renaming over a file replaces it; unlink and rmdir remove paths.
unittest
{
	auto d = parseStream(header(1) ~ snapshot ~
		cmd(P.Cmd.write, path("a"), data(5)) ~
		cmd(P.Cmd.write, path("b"), data(7)) ~
		cmd(P.Cmd.rename, path("b"), pathTo("a")) ~
		cmd(P.Cmd.write, path("c"), data(3)) ~
		cmd(P.Cmd.rename, path("untouched"), pathTo("c")) ~
		cmd(P.Cmd.write, path("gone/file"), data(11)) ~
		cmd(P.Cmd.unlink, path("gone/file")) ~
		cmd(P.Cmd.rmdir, path("gone")) ~
		end, "@subvol-1");
	assert(d.dataBytes == 5 + 7 + 3 + 11);
	assert(d.tree.size == 7);
	assert(d.tree.children["a"].size == 7);
	assert(d.tree.children["c"].size == 0);
	assert("b" !in d.tree.children);
	assert("gone" !in d.tree.children);
}

// v2: implicit data length; encoded writes count their logical length.
unittest
{
	auto d = parseStream(header(2) ~ snapshot ~
		cmd(P.Cmd.write, path("a"), tlv(18, new ubyte[8]), nativeToLittleEndian(cast(ushort)P.Attr.data) ~ new ubyte[70000]) ~
		cmd(P.Cmd.encodedWrite, path("b"), u64(P.Attr.unencodedFileLen, 131072), nativeToLittleEndian(cast(ushort)P.Attr.data) ~ new ubyte[4096]) ~
		end, "@subvol-1");
	assert(d.tree.children["a"].size == 70000);
	assert(d.tree.children["b"].size == 131072);
}

// --no-data streams describe writes with update_extent.
unittest
{
	auto d = parseStream(header(1) ~ snapshot ~
		cmd(P.Cmd.updateExtent, path("a"), u64(18, 0), u64(P.Attr.size, 1 << 20)) ~
		end, "@subvol-1");
	assert(d.dataBytes == 1 << 20);
}

// Invalid UTF-8 in paths is replaced.
unittest
{
	auto d = parseStream(header(1) ~ snapshot ~
		cmd(P.Cmd.write, path("\xFF.bin"), data(1)) ~
		end, "@subvol-1");
	assert(d.tree.children.keys == ["�.bin"]);
}

// Malformed streams are rejected.
unittest
{
	auto good = header(1) ~ snapshot ~ cmd(P.Cmd.write, path("a"), data(1)) ~ end;
	parseStream(good, "@subvol-1");
	assertThrown(parseStream(good[0 .. $ - 1], "@subvol-1")); // truncated
	assertThrown(parseStream(good[0 .. $ - end.length], "@subvol-1")); // no end
	assertThrown(parseStream(good ~ end, "@subvol-1")); // data after end
	assertThrown(parseStream(good, null)); // incremental, but no parent
	assertThrown(parseStream(cast(ubyte[])"btrfs-strean\0" ~ good[13 .. $], "@subvol-1"));
	assertThrown(parseStream(header(4) ~ good[17 .. $], "@subvol-1"));
	assertThrown(parseStream(header(1) ~ snapshot ~ cmd(P.Cmd.fallocate, path("a")) ~ end, "@subvol-1")); // v2 command in v1
	assertThrown(parseStream(header(1) ~ snapshot ~ cmd(P.Cmd.write, data(1)) ~ end, "@subvol-1")); // no path
	assertThrown(parseStream(header(1) ~ cmd(P.Cmd.write, path("a"), data(1)) ~ snapshot ~ end, "@subvol-1"));
}
