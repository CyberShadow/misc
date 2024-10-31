#!/usr/bin/env dub
/+ dub.sdl: +/

/**
   CIDR range calculator.
   E.g.: netcalc '192.168.0.0/24 + 10.0.0.0/8 - 192.168.0.128/25'
*/

import std.algorithm.iteration : map, joiner;
import std.algorithm.searching : findSplit, canFind, startsWith, skipOver;
import std.array : split, array, join;
import std.conv : to;
import std.exception : enforce;
import std.range : iota;
import std.string : strip, indexOf, lastIndexOf;
import std.sumtype : SumType, match;
import std.string : format;
import std.typecons : Tuple, tuple;

struct Block
{
	alias Value = SumType!(
		bool,
		Block[2],
	);
	immutable(Value)* value;
	this(bool value) { this.value = new Value(value); }
	this(Block[2] value) { this.value = new Value(value); }

	Block opUnary(string op : "~")() const
	{
		return (*value).match!(
			(bool b) { return Block(!b); },
			(Block[2] blocks) {
				return Block([~blocks[0], ~blocks[1]]);
			},
		);
	}

	Block opBinary(string op : "+")(Block rhs) const
	{
		return (*value).match!(
			(bool b) { return b ? fullBlock : rhs; },
			(Block[2] lhs) {
				return (*rhs.value).match!(
					(bool b) { return b ? fullBlock : this; },
					(Block[2] rhs) {
						return Block([
							lhs[0] + rhs[0],
							lhs[1] + rhs[1],
						]);
					},
				);
			},
		);
	}

	Block opBinary(string op : "-")(Block rhs) const
	{
		return (*value).match!(
			(bool b) {
				return b ? ~rhs : emptyBlock;
			},
			(Block[2] lhs) {
				return (*rhs.value).match!(
					(bool b) {
						return b ? emptyBlock : this;
					},
					(Block[2] rhs) {
						return Block([
							lhs[0] - rhs[0],
							lhs[1] - rhs[1],
						]);
					},
				);
			},
		);
	}

	string toString() const
	{
		Tuple!(uint, uint)[] ranges;
		void traverse(const Block b, uint prefix, uint length)
		{
			(*b.value).match!(
				(bool full) {
					if (full)
						ranges ~= tuple(prefix, length);
				},
				(const Block[2] blocks) {
					traverse(blocks[0], prefix, length + 1);
					traverse(blocks[1], prefix | (1 << (31 - length)), length + 1);
				}
			);
		}
		traverse(this, 0, 0);

		string[] result;
		foreach (range; ranges)
		{
			result ~= format("%d.%d.%d.%d/%d",
				(range[0] >> 24) & 0xFF,
				(range[0] >> 16) & 0xFF,
				(range[0] >> 8) & 0xFF,
				range[0] & 0xFF,
				range[1]
			);
		}
		return result.join(" + ");
	}
}

immutable fullBlock = Block(true);
immutable emptyBlock = Block(false);

immutable(Block) parseRange(string s)
{
	auto parts = s.findSplit("/");

	bool[] address;
	if (parts[0].canFind("."))
		address = parts[0]
			.split(".")
			.map!(n => n.to!ubyte)
			.map!(n => 8.iota.map!(bit => !!((1 << (7 - bit)) & n)))
			.joiner
			.array;
	else
	if (parts[0].canFind(":"))
		address = parts[0]
			.split(":")
			.map!(n => n.length ? n.to!ushort(16) : 0)
			.map!(n => 16.iota.map!(bit => !!((1 << (15 - bit)) & n)))
			.joiner
			.array;
	else
		throw new Exception("Unknown address format");

	size_t length;
	if (parts)
		length = parts[2].to!uint;
	else
		length = address.length; // /32 for IPv4, /128 for IPv6
	enforce(length <= address.length, "Invalid length");

	Block b = fullBlock;
	foreach_reverse (i; 0 .. length)
		if (address[i])
			b = Block([emptyBlock, b]);
		else
			b = Block([b, emptyBlock]);
	return b;
}

Block parseExpr(string expr)
{
	Block parseSimple(ref string e)
	{
		e = e.strip();
		if (e.startsWith("("))
		{
			auto end = e.lastIndexOf(")");
			if (end == -1)
				throw new Exception("Unmatched parenthesis");
			auto result = parseExpr(e[1..end]);
			e = e[end+1..$];
			return result;
		}
		else if (e.startsWith("~"))
		{
			e = e[1..$];
			return ~parseSimple(e);
		}
		else
		{
			auto end = e.indexOf(" ");
			if (end == -1)
				end = e.length;
			auto result = parseRange(e[0..end]);
			e = e[end..$];
			return result;
		}
	}

	Block result = parseSimple(expr);
	expr = expr.strip();
	while (expr.length)
	{
		if (expr.skipOver("+"))
			result = result + parseSimple(expr);
		else if (expr.skipOver("-"))
			result = result - parseSimple(expr);
		else
			throw new Exception("Invalid expression: " ~ expr);
		expr = expr.strip();
	}
	return result;
}

unittest
{
	assert(parseRange("192.168.0.0/24").toString() == "192.168.0.0/24");
	// assert(parseRange("2001:db8::/32").toString() == "2001:db8::/32"); // TODO

	auto expr = "192.168.0.0/24 + 10.0.0.0/8 - 192.168.0.128/25";
	auto result = parseExpr(expr);
	assert(result.toString() == "10.0.0.0/8 + 192.168.0.0/25");

	assert(parseExpr("~(192.168.0.0/24)").toString() == "0.0.0.0/1 + 128.0.0.0/2 + 192.0.0.0/9 + 192.128.0.0/11 + 192.160.0.0/13 + 192.168.1.0/24 + 192.168.2.0/23 + 192.168.4.0/22 + 192.168.8.0/21 + 192.168.16.0/20 + 192.168.32.0/19 + 192.168.64.0/18 + 192.168.128.0/17 + 192.169.0.0/16 + 192.170.0.0/15 + 192.172.0.0/14 + 192.176.0.0/12 + 192.192.0.0/10 + 193.0.0.0/8 + 194.0.0.0/7 + 196.0.0.0/6 + 200.0.0.0/5 + 208.0.0.0/4 + 224.0.0.0/3");
}

void main(string[] args)
{
	enforce(args.length == 2, "Usage: " ~ args[0] ~ " EXPR");
	import std.stdio : stdout;
	stdout.writeln(parseExpr(args[1]));
}
