import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.exception;
import std.file;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.main;
import ae.utils.funopt;
import ae.utils.regex;

enum initialBootNum = 2000;
enum grubConfig = "/boot/grub/grub.cfg";

void grub2efi(bool dryRun)
{
	void maybeRun(string[] command, lazy File output = stdout)
	{
		stderr.writefln("%s: %s", dryRun ? "Would run" : "Running", escapeShellCommand(command));
		if (!dryRun)
			enforce(spawnProcess(command, stdin, output).wait() == 0, command[0] ~ " failed");
	}

	maybeRun(["grub-mkconfig"], File(grubConfig, "wb"));

	string disk, diskPart;
	foreach (mount; getMounts())
		if (mount.file == "/boot")
		{
			auto m = mount.spec.matchFirst(regex("^(/dev/.d[a-z])([0-9]+)$"));
			enforce(m, "Can't parse boot disk path");
			disk = m[1];
			diskPart = m[2];
		}
	enforce(disk, "Can't detect boot disk");
	stderr.writeln("Detected boot disk: ", disk);

	string[int] bootEntries;
	{
		auto result = execute(["efibootmgr"]);
		enforce(result.status == 0, "efibootmgr failed");
		foreach (l; result.output.splitLines)
			l.matchCaptures(re!`^Boot(\d\d\d\d)\* (.*)$`,
				(int num, string name)
				{
					bootEntries[num] = name;
				});
	}

	string name, kernel;
	string[] initrd, parameters;

	int bootNum = initialBootNum;

	foreach (line; readText(grubConfig).splitLines())
	{
		auto args = line.strip().argSplit();
		if (args[0] == "menuentry")
		{
			//enforce(args[$-1] == "{"); args = args[0..$-1];
			name = args[1];
		}
		else
		if (args[0] == "linux")
		{
			kernel = args[1];
			parameters = args[2..$];
		}
		else
		if (args[0] == "initrd")
			initrd = args[1..$];
		else
		if (args == ["}"] && name)
		{
			// if (bootNum in bootEntries)
			// 	maybeRun(["efibootmgr", 

			auto commandLine = parameters ~ initrd.map!(path => "initrd=" ~ path).array;
			maybeRun([
				"efibootmgr",
				"--bootnum", text(bootNum++),
				"--gpt",
				"--disk", disk,
				"--part", diskPart,
				"--label", name,
				"--loader", kernel,
				"--unicode", commandLine.map!escapeKernelParam.join(" "),
			] ~ (bootNum in bootEntries ? [] : ["--create"]));

			name = kernel = null;
			initrd = parameters = null;
		}
	}

	auto lastBootNum = bootNum;

	// Delete trailing bootnums
	while (bootNum in bootEntries)
	 	maybeRun([
			"efibootmgr",
			"--bootnum", text(bootNum++),
			"--delete-bootnum"
		]);

	auto order = iota(initialBootNum, lastBootNum).chain(bootEntries.keys.sort().filter!(n => n < initialBootNum || n > lastBootNum));
	maybeRun(["efibootmgr", "--bootorder", order.map!(n => "%04d".format(n)).join(",")]);
}

string[] argSplit(string s)
{
	string[] result;
	string current;
	bool quoted;
	foreach (c; s)
		if (c == '\'')
			quoted = !quoted;
		else
		if (isWhite(c) && !quoted)
		{
			result ~= current;
			current = null;
		}
		else
			current ~= c;
	result ~= current;
	return result;
}

string escapeKernelParam(string s)
{
	foreach (c; s)
		if (isWhite(c))
			return '\'' ~ s ~ '\'';
	return s;
}

mixin main!(funopt!grub2efi);
