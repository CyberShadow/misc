module stream_mode_i3;

import ae.utils.json;
import ae.utils.regex;

import std.exception;
import std.process;
import std.regex;
import std.stdio;

void main()
{
	auto treeRes = execute(["i3-msg", "-t", "get_tree"]);
	enforce(treeRes.status == 0, "i3-msg failed");
	auto treeStr = treeRes.output;

	treeStr = treeStr
		.replaceAll(re!`// ("(class|instance|title|transient_for|window_role)": ")`, "$1")
		.replaceAll(re!`// .*`, "")
		.replaceAll(re!"\n\n\\{", ",\n{")
	;

	static struct Rect
	{
		int height, width, x, y;
	}

	static struct Spec
	{
	}

	static struct Node
	{
		int id;
		string type;
		string orientation;
		string scratchpad_state;
		real* percent;
		bool urgent;
		bool focused;
		string output;
		string layout;
		string workspace_layout;
		string last_split_layout;
		string border;
		int current_border_width;
		Rect rect;
		Rect deco_rect;
		Rect window_rect;
		Rect geometry;
		string name;
		int num;
		struct Gaps { int inner; int outer; }
		Gaps gaps;
		int* window;
		struct Props { @JSONName("class") string class_; string instance, title, transient_for, window_role; }
		Props window_properties;
		Node[] nodes;
		Node[] floating_nodes;
		int[] focus;
		int fullscreen_mode;
		bool sticky;
		string floating;
		struct Swallow { int dock, insert_where; }
		Swallow[] swallows; // ?
	}

	//treeStr = "[" ~ treeStr ~ "]";

	auto root = jsonParse!Node(treeStr);
	enforce(root.type == "root");
	foreach (output; root.nodes)
	{
		enforce(output.type == "output");
		if (output.name != "DP-1.8")
			continue;

		foreach (onode; output.nodes)
			if (onode.type == "con")
				foreach (ws; onode.nodes)
				{
					enforce(ws.type == "workspace");
					if (ws.layout != "splitv")
					writeln(ws.type, " ", ws.name, " ", ws.layout);
				}
	}
}
