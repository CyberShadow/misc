/**
   Convert grub menu entries to EFI boot entries.
*/

import std.algorithm;
import std.array;
import std.ascii;
import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;

import ae.sys.file;
import ae.utils.main;
import ae.utils.funopt;
import ae.utils.regex;

enum grubConfig = "/boot/grub/grub.cfg";
enum linkDir = "/var/local/grub2efi/links/";

void grub2efi(bool dryRun, bool noGrubMkconfig, int initialBootNum = 2000)
{
	void log(string s)
	{
		stderr.writeln("grub2efi: ", s);
	}

	void maybeDo(scope void delegate() action, string desc = null)
	{
		if (desc)
			log(desc);
		if (!dryRun)
			action();
	}

	void maybeRun(string[] command, lazy File output = stdout)
	{
		maybeDo({ enforce(spawnProcess(command, stdin, output).wait() == 0, command[0] ~ " failed"); },
			format("%s: %s", dryRun ? "Would run" : "Running", escapeShellCommand(command)));
	}

	if (!noGrubMkconfig)
	{
		static immutable string tmp = grubConfig ~ ".tmp";
		scope(failure) maybeDo({ if (tmp.exists) tmp.remove(); });
		maybeRun(["grub-mkconfig"], File(tmp, "wb"));
		maybeDo({ rename(tmp, grubConfig); });
	}

	string disk, diskPart;
	foreach (mount; getMounts())
		if (mount.file == "/boot")
		{
			auto m = mount.spec.matchFirst(regex("^(/dev/.d[a-z])([0-9]+)$"));
			if (!m)
				m = mount.spec.matchFirst(regex("^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$"));
			enforce(m, "Can't parse boot disk path");
			disk = m[1];
			diskPart = m[2];
		}
	enforce(disk, "Can't detect boot disk");
	log("Detected boot disk: " ~ disk);

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

	if (linkDir.exists)
		maybeDo({ rmdirRecurse(linkDir); },
			format("%s %s", dryRun ? "Would clean up" : "Cleaning up", linkDir));

	void maybePut(string fileName, string contents)
	{
		maybeDo({ ensurePathExists(fileName); std.file.write(fileName, contents); },
			format("%s %s", dryRun ? "Would create" : "Creating", fileName));
	}

	string name, kernel;
	string[] initrd, parameters;
	bool[string] sawKernel;

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
			if (kernel)
			{
				if (bootNum in bootEntries)
					maybeRun(["efibootmgr", "--bootnum", text(bootNum), "--delete-bootnum"]);

				auto commandLine = parameters ~ initrd.map!(path => "initrd=" ~ path).array;
				maybeRun([
					"efibootmgr",
					"--create",
					"--bootnum", text(bootNum),
					"--gpt",
					"--disk", disk,
					"--part", diskPart,
					"--label", "%d. %s".format(bootNum - initialBootNum + 1, name),
					"--loader", kernel,
					"--unicode", commandLine.map!escapeKernelParam.join(" "),
				]);

				maybePut(linkDir ~ "/by-name/" ~ name, text(bootNum));
				if (kernel.baseName() !in sawKernel)
				{
					maybePut(linkDir ~ "/by-kernel/" ~ kernel.baseName(), text(bootNum));
					sawKernel[kernel.baseName()] = true;
				}

				bootNum++;
			}
			name = kernel = null;
			initrd = parameters = null;
		}
	}

	log("Found %d boot entries.".format(bootNum - initialBootNum));

	auto lastBootNum = bootNum;

	// Delete trailing bootnums
	while (bootNum in bootEntries)
	{
	 	maybeRun([
			"efibootmgr",
			"--bootnum", text(bootNum++),
			"--delete-bootnum"
		]);
		bootEntries.remove(bootNum);
	}

	auto order = iota(initialBootNum, lastBootNum).chain(bootEntries.keys.sort().filter!(n => n < initialBootNum || n > lastBootNum));
	maybeRun(["efibootmgr", "--bootorder", order.map!(n => "%04d".format(n)).join(",")]);
}

string[] argSplit(string s)
{
	string[] result;
	string current;
	char quoted = 0;
	bool escaped = false;
	foreach (c; s)
		if (escaped)
		{
			current ~= c;
			escaped = false;
		}
		else
		if (quoted && c == quoted)
			quoted = 0;
		else
		if (!quoted && (c == '\'' || c == '"'))
			quoted = c;
		else
		if (isWhite(c) && !quoted)
		{
			if (current.length)
				result ~= current;
			current = null;
		}
		else
		if (quoted != '\'' && c == '\\')
			escaped = true;
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
