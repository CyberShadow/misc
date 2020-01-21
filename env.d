/**
   A cross-platform implementation of env, as in coreutils.
*/

module env;

import std.ascii;
import std.file;
import std.getopt;
import std.process;
import std.stdio;
import std.string;

int main(string[] args)
{
	bool ignoreEnvironment;
	string terminator = newline;
	string[] unset;
	string[2][] vars;
	string dir;
	string[] command;

	{
		bool parsingSwitches = true;
		bool inProgram;
		bool help;

		void processOptions(string[] options)
		{
			while (options.length)
			{
				if (inProgram)
				{
					command ~= options;
					return;
				}

				if (parsingSwitches && options[0].startsWith("-"))
				{
					if (options[0].length == 1) // -
					{
						ignoreEnvironment = true;
						options = options[1 .. $];
						continue;
					}

					if (options[0] == "--")
					{
						parsingSwitches = false;
						options = options[1 .. $];
						continue;
					}

					auto args = ["program"] ~ options;
					auto helpInformation = getopt(args,
						config.caseSensitive,
						config.bundling,
						config.stopOnFirstNonOption,
						config.keepEndOfOptions,
						"i|ignore-environment", "start with an empty environment", &ignoreEnvironment,
						"0|null", "end each output line with NUL, not newline", { terminator = "\0"; },
						"u|unset", "remove variable from the environment", &unset,
						"C|chdir", "change working directory", &dir,
					//	"S|split-string", "process and split string into separate arguments", (string s) { processOptions(shellSplit(s)); },
					);

					if (helpInformation.helpWanted)
					{
						if (!help)
							defaultGetoptPrinter("run a program in a modified environment", helpInformation.options);
						help = true;
						return;
					}

					assert(args.length != 1 + options.length, "getopt did not consume options?");
					options = args[1 .. $];
					continue;
				}

				sizediff_t p = options[0].indexOf('=');
				if (p >= 0)
				{
					vars ~= [options[0][0 .. p], options[0][p + 1 .. $]];
					options = options[1 .. $];
					continue;
				}

				inProgram = true;
			}
		}

		processOptions(args[1..$]);
		if (help)
			return 0;
	}

	if (!command)
	{
		foreach (name, value; environment.toAA)
			writef("%s=%s%s", name, value, terminator);
		return 0;
	}

	string[string] env;
	if (!ignoreEnvironment)
		env = environment.toAA;

	foreach (name; unset)
		env.remove(name);
	foreach (var; vars)
		env[var[0]] = var[1];

	version (Posix)
	{
		string[] envp;
		foreach (name, value; env)
			envp ~= name ~ '=' ~ value;
		if (dir)
			chdir(dir);
		execvpe(command[0], command, envp);
		throw new Exception("exec failed");
	}
	else
	{
		return spawnProcess(
			command,
			stdin, stdout, stderr,
			env,
			Config.newEnv | Config.inheritFDs,
			dir
		).wait();
	}
}
