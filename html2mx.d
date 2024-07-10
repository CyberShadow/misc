#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Basic program to convert HTML to something accepted by the Element Matrix client.
*/

import std.algorithm.searching;
import std.array;
import std.exception;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.xml.helpers;
import ae.utils.xml.lite;

struct ParseConfig
{
static:
	NodeCloseMode nodeCloseMode(string tag) { return NodeCloseMode.always; }
	bool preserveWhitespace(string tag) { return true; }
	enum optionalParameterValues = true;
}

void main()
{
	auto html = cast(string)readFile(stdin);
	auto doc = parseDocument!ParseConfig(html);

	void visit(ref XmlNode n)
	{
		auto o = n;

		bool noSelfClose = false;
		if (n.type == XmlNodeType.Node)
			switch (n.tag)
			{
				case "font":
					noSelfClose = true;
					break;
				case "span":
					n.tag = "font";
					noSelfClose = true;
					break;
				default:
					stderr.writeln("Warning: Unknown tag: ", n.tag);
			}
		if (noSelfClose && n.children.length == 0)
			n.children ~= newTextNode("");

		foreach (name, value; n.attributes.dup)
			switch (name)
			{
				case "style":
					n.attributes.remove("style");
					foreach (decl; value.split(";"))
					{
						auto parts = decl.strip.findSplit(":").enforce("Invalid CSS");
						auto styleName = parts[0].strip, styleValue = parts[2].strip;
						switch (styleName)
						{
							case "color":
								n.attributes["data-mx-color"] = styleValue;
								break;
							case "background-color":
								n.attributes["data-mx-bg-color"] = styleValue;
								break;
							case "font-weight":
								switch (styleValue)
								{
									case "bold":
										o = newNode(XmlNodeType.Node, "b", null, [o]);
										break;
									default:
										stderr.writeln("Warning: Unknown font-weight: ", styleValue);
								}
								break;
							default:
								stderr.writeln("Warning: Unknown style: ", styleName);
						}
					}
					break;
				default:
					stderr.writeln("Warning: Unknown attribute: ", name);
			}

		foreach (child; n.children)
			visit(child);

		n = o;
	}
	foreach (child; doc.children)
		visit(child);

	stdout.write(doc.toString());
}
