module stream_mode_i3;

import ae.utils.json;
import ae.utils.regex;

import std.exception;
import std.process;
import std.regex;
import std.stdio;

void main()
{
	auto treeRes = execute(["i3-save-tree", "--OUTPUT=DP-1.8"]);
	enforce(treeRes.status == 0, "i3-save-tree failed");
	auto treeStr = treeRes.output;

	treeStr = treeStr
		.replaceAll(re!`// ("(class|instance|title|transient_for|window_role)": ")`, "$1")
		.replaceAll(re!`// .*`, "")
		.replaceAll(re!"\n\n\\{", ",\n{")
	;

	static struct Geometry
	{
		int height, width, x, y;
	}

	static struct Spec
	{
		@JSONName("class")
		string class_;
		string instance, title, transient_for, window_role;
	}

	static struct Node
	{
		string border;
		string current_border_width;
		string floating;
		int fullscreen_mode;
		string layout;
		Geometry geometry;
		string name;
		real percent;
		string type;
		Node[] nodes;
		Spec[] swallows;
	}

	treeStr = "[" ~ treeStr ~ "]";

	auto workspaces = jsonParse!(Node[])(treeStr);
	writeln(treeStr);

	
}
