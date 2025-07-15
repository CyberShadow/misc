#!/usr/bin/env dub
/+ dub.sdl:
dependency "ae" version="==0.0.3636"
+/

/**
   Convert between tabular formats.
 */

module tab2tab;

import std.algorithm.iteration : map, filter;
import std.algorithm.searching : canFind, countUntil, startsWith, countUntil, all;
import std.array : array, split, replicate, join, replace;
import std.conv : to;
import std.csv : csvReader;
import std.exception : assumeUnique, enforce;
import std.format.write : formattedWrite;
import std.json : parseJSON, JSONOptions, JSONType, JSONValue, toJSON;
import std.range : iota, chain, only;
import std.range.primitives : empty;
import std.stdio : File, writefln;
import std.string : assumeUTF, splitLines, strip;
import std.typecons : tuple, Nullable, nullable;

import ae.sys.file : readFile;
import ae.utils.aa;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text : asText;
import ae.utils.text.csv : putCSV;

struct Table
{
	string[] headers;
	string[][] rows;
}

abstract class Format
{
	abstract string name();
	abstract Table read(File);
	abstract void write(File, Table);
}

private string[][] normalizeRows(string[][] rows, size_t numColumns)
{
	foreach (ref row; rows)
	{
		if (row.length < numColumns)
			row.length = numColumns;
		else if (row.length > numColumns)
			row.length = numColumns; // Truncate
	}
	return rows;
}

void program(
	Option!(string, "Format to convert from.") from,
	Option!(string, "Format to convert to.") to,
	Switch!("Escape Markdown cells.") mdEscape = false,
	Option!(string, "Table name for SQL output.") tableName = "table",
	Parameter!(string, "Input file (default: stdin).") inputFileName = null,
	Parameter!(string, "Output file (default: stdout).") outputFileName = null,
)
{
	auto t = (File f) {
		switch (from)
		{
			case "csv":
				auto lines = f
					.readFile()
					.asText
					.csvReader;
				if (lines.empty)
					return Table.init;

				auto headers = lines.front.array;
				lines.popFront(); // https://github.com/dlang/phobos/issues/10636

				auto rows = lines
					.map!(line => line.array)
					.array;

				return Table(
					headers: headers,
					rows: normalizeRows(rows, headers.length),
				);

			case "tsv":
				auto lines = f
					.readFile()
					.assumeUnique
					.asText
					.splitLines;
				if (lines.empty)
					return Table.init;

				auto headers = lines[0].split('\t');
				auto rows = lines[1..$].map!(line => line.split('\t')).array;

				return Table(
					headers: headers,
					rows: normalizeRows(rows, headers.length),
				);

			case "json":
				static if (__traits(hasMember, JSONOptions, "preserveObjectOrder"))
				{
					auto jsonText = f.readFile().assumeUnique.asText;
					auto json = jsonText.parseJSON(JSONOptions.preserveObjectOrder);
					enforce(json.type == JSONType.array, "JSON input is not an array");
					if (json.array.empty)
						return Table.init;
					enforce(json.array.all!(o => o.type == JSONType.object), "JSON input is not an array of objects");

					struct Column
					{
						string name;
						string delegate(JSONValue row) get;
					}
					Column[] columns;
					void visit(JSONValue o, string prefix, Nullable!JSONValue delegate(JSONValue) get)
					{
						switch (o.type)
						{
							case JSONType.object:
								foreach (pair; o.orderedObject)
									(string key) {
										visit(
											pair.value,
											prefix ~ (prefix ? "." : "") ~ key,
											(JSONValue root) {
												auto o = get(root);
												return !o.isNull && o.get.type == JSONType.object && key in o.get.objectNoRef
													? o.get.objectNoRef[key].nullable
													: Nullable!JSONValue();
											}
										);
									}(pair.key);
								break;
							case JSONType.array:
								foreach (i, value; o.array)
									(size_t i) {
										visit(
											value,
											prefix ~ "[" ~ i.to!string ~ "]",
											(JSONValue root) {
												auto o = get(root);
												return !o.isNull && o.get.type == JSONType.array && i < o.array.length
													? o.array[i].nullable
													: Nullable!JSONValue();
											}
										);
									}(i);
								break;
							case JSONType.string:
								columns ~= Column(
									name: prefix,
									get: (JSONValue root) {
										auto o = get(root);
										return !o.isNull && o.get.type == JSONType.string
											? o.get.str
											: null;
									},
								);
								break;
							default:
								columns ~= Column(
									name: prefix,
									get: (root) => get(root).toString(),
								);
						}
					}
					visit(json.array[0], null, (JSONValue o) => o.nullable);

					auto headers = json.array[0].objectNoRef.keys;
					return Table(
						headers: columns.map!((ref c) => c.name).array,
						rows: json.array.map!((JSONValue o) => columns.map!((ref c) => c.get(o)).array).array,
					);
				}
				else
					throw new Exception("Cannot read JSON - your std.json cannot preserve object order.");

			case "psql":
				auto lines = f.readFile().assumeUnique.asText.splitLines.array;
				if (lines.length < 2)
					return Table.init;

				auto sepLineIdx = lines.countUntil!(line => line.strip.length > 0 && line.strip.all!(c => c == '-' || c == '+'));

				if (sepLineIdx == -1 || sepLineIdx == 0)
					throw new Exception("Could not find psql-style separator line (e.g. '---+---')");

				auto parseRow = (string line) => line.split('|').map!(s => s.strip).array;

				auto headers = parseRow(lines[sepLineIdx - 1]);
				auto dataLines = lines[sepLineIdx + 1 .. $];
				auto footerIdx = dataLines.countUntil!(line => line.strip.startsWith("("));
				if (footerIdx != -1)
					dataLines = dataLines[0 .. footerIdx];

				auto borderIdx = dataLines.countUntil!(line => line.strip.startsWith("+--"));
				if (borderIdx != -1)
					dataLines = dataLines[0 .. borderIdx];

				auto rows = dataLines.map!parseRow.array;
				return Table(headers, normalizeRows(rows, headers.length));

			case "md":
			case "org":
				// This unified parser handles both Markdown and Org-Mode tables
				auto lines = f.readFile().assumeUnique.asText.splitLines
					.map!(a => a.strip)
					.filter!(a => a.length > 0 && a.startsWith("|"))
					.array;

				// Helper to parse a row like `| a | b |`
				auto parsePipedRow = (string line) {
					auto s = line;
					if (s.length > 1 && s[0] == '|') s = s[1..$];
					if (s.length > 0 && s[$-1] == '|') s = s[0..$-1];
					return s.split('|').map!(c => c.strip()).array;
				};

				alias isSeparatorLine = line => line.startsWith("|-") || line.startsWith("| ---");
				lines = lines.filter!(line => !isSeparatorLine(line)).array;
				if (lines.empty)
					return Table.init;
				auto headers = parsePipedRow(lines[0]);
				auto rows = lines[1..$].map!parsePipedRow.array;
				return Table(headers, normalizeRows(rows, headers.length));

			default:
				throw new Exception("Unknown input format: " ~ from);
		}
	}(inputFileName ? imported!"std.stdio".File(inputFileName, "rb") : imported!"std.stdio".stdin);

	(File f) {
		switch (to)
		{
			case "csv":
				f.lockingTextWriter.putCSV(t.headers, t.rows);
				break;

			case "tsv":
				auto w = f.lockingTextWriter;
				foreach (line; chain(t.headers.only, t.rows))
				{
					foreach (i, cell; line)
					{
						if (i > 0)
							w.put('\t');
						w.put(cell);
					}
					w.put('\n');
				}
				break;

			case "md":
				static string escapeMarkdown(string s)
				{
					if (!s.length)
						return "";
					size_t numQuotes, maxNumQuotes;
					foreach (c; s)
						if (c == '`')
						{
							numQuotes++;
							if (numQuotes > maxNumQuotes)
								maxNumQuotes = numQuotes;
						}
						else
							numQuotes = 0;
					auto delimiter = "`".replicate(maxNumQuotes + 1);
					return delimiter ~ s ~ delimiter;
				}

				auto processCell = mdEscape ? &escapeMarkdown : (string s) => s;
				f.writefln("| %-(%s |%| %)", t.headers.map!processCell);
				f.writefln("| %-(%s |%| %)", t.headers.map!(s => "---"));
				foreach (row; t.rows)
					f.writefln("| %-(%s |%| %)", row.map!processCell);
				break;

			case "org":
				auto w = f.lockingTextWriter;
				w.formattedWrite("| %-(%s |%| %)\n", t.headers);
				if (t.headers.length > 0)
				{
					// Write a separator line like |---+---|
					w.put("|-");
					bool first = true;
					foreach(h; t.headers)
					{
						if (!first) w.put("+-");
						// writefln adds spaces, so we replicate based on header length + 2
						w.put("-".replicate(h.length + 2)); 
						first = false;
					}
					w.put("-|\n");
				}
				foreach (row; t.rows)
					w.formattedWrite("| %-(%s |%| %)\n", row);
				break;

			case "json":
				static if (__traits(hasMember, JSONOptions, "preserveObjectOrder"))
				{
					JSONValue[] rows;
					foreach (row; t.rows)
					{
						auto obj = JSONValue.emptyOrderedObject;
						foreach (i, h; t.headers)
						{
							if (i < row.length)
								obj[h] = JSONValue(row[i]);
						}
						rows ~= obj;
					}
					auto doc = JSONValue(rows);
					f.write(doc.toJSON());
					break;
				}
				else
					throw new Exception("Cannot write JSON - your std.json cannot preserve object order.");

			case "sql":
				auto w = f.lockingTextWriter;

				enum escapeSqlIdentifier = (string s) => `"` ~ s.replace(`"`, `""`) ~ `"`;
				enum escapeSql = (string s) => s is null ? "NULL" : "'" ~ s.replace("'", "''") ~ "'";

				foreach(row; t.rows)
					w.formattedWrite("INSERT INTO %s (%-(%s, %)) VALUES (%-(%s, %));\n",
						escapeSqlIdentifier(tableName),
						t.headers.map!escapeSqlIdentifier,
						row.map!escapeSql,
					);
				break;

			case "html":
				static string escapeHtml(string s)
				{
					return s.replace("&", "&amp;")
							.replace("<", "&lt;")
							.replace(">", "&gt;");
				}

				auto w = f.lockingTextWriter;
				w.put("<table>\n");
				w.put("  <thead>\n");
				w.put("    <tr>\n");
				foreach (h; t.headers)
					w.formattedWrite("      <th>%s</th>\n", escapeHtml(h));
				w.put("    </tr>\n");
				w.put("  </thead>\n");
				w.put("  <tbody>\n");
				foreach (row; t.rows)
				{
					w.put("    <tr>\n");
					foreach (cell; row)
						w.formattedWrite("      <td>%s</td>\n", escapeHtml(cell));
					w.put("    </tr>\n");
				}
				w.put("  </tbody>\n");
				w.put("</table>\n");
				break;

			default:
				throw new Exception("Unknown output format: " ~ to);
		}
	}(outputFileName ? imported!"std.stdio".File(outputFileName, "wb") : imported!"std.stdio".stdout);
}

mixin main!(funopt!program);
