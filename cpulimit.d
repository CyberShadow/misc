#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/**
   Simple but flexible per-process CPU limiter.
*/

import std.exception;

import ae.utils.funopt;
import ae.utils.main;

import core.sys.posix.signal;
import core.sys.posix.sys.types;
import core.sys.posix.unistd;

__gshared bool stop, paused;

extern(C) void sighandler(int) nothrow @nogc
{
	if (paused)
		stop = true;
	else
		_exit(0);
}

void cpulimit(
	Parameter!(pid_t, "PID of process/thread to throttle") pid,
	Parameter!(uint, "Pause time in microseconds") pause,
	Parameter!(uint, "Active time in microseconds") active,
)
{
	signal(SIGTERM, &sighandler);
	signal(SIGINT, &sighandler);

	while (!stop)
	{
		paused = false;
		usleep(active);

		paused = true;
		errnoEnforce(kill(pid, SIGSTOP) == 0);
		usleep(pause);
		errnoEnforce(kill(pid, SIGCONT) == 0);
	}
}

mixin main!(funopt!cpulimit);
