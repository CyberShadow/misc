/// Simple HTTP load balancer with auto-scaling.
module clb;

import core.time;

import std.algorithm.iteration;
import std.algorithm.mutation : SwapStrategy;
import std.algorithm.searching;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.ascii;
import std.conv : to;
import std.exception : collectException, enforce;
import std.file : remove;
import std.parallelism : totalCPUs;
import std.process;
import std.socket : AddressInfo, AddressFamily, SocketType, UnixAddress;
import std.stdio : stderr;
import std.string : isNumeric, representation;
import std.typecons : Nullable, apply;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.server;
import ae.net.shutdown;
import ae.sys.dataset;
import ae.sys.timing;
import ae.utils.array;
import ae.utils.funopt;
import ae.utils.json;
import ae.utils.main;
import ae.utils.text : splitByCamelCase;
import ae.utils.typecons : flatten;
import ae.utils.xml.entities : encodeEntities;

struct KillRule
{
	Duration time;
	int signal;
}

string[] workerCommand;
size_t maxPipelining;
ulong maxRequests;
Duration maxIdleTime;
Duration workerTimeout;
bool retry;
KillRule[] killRules;

final class NullConnector : Connector
{
	IConnection connection;
	this(IConnection c) { this.connection = c; }
	override IConnection getConnection() { return connection; }
	override void connect(string host, ushort port) {}
}

// Work around https://issues.dlang.org/show_bug.cgi?id=23923
import ae.utils.promise : Promise;
Promise!(T, E) threadAsync(T, E = Exception)(T delegate() value)
{
	import core.thread : Thread;
	import std.typecons : No;
	import ae.net.sync : ThreadAnchor;
	import ae.utils.meta : voidStruct;

	auto p = new Promise!T;
	auto mainThread = new ThreadAnchor(No.daemon);
	Thread t;
	t = new Thread({
		try
		{
			auto result = value().voidStruct;
			mainThread.runAsync({
				t.join();
				p.fulfill(result.tupleof);
			});
		}
		catch (Exception e)
			mainThread.runAsync({
				t.join();
				p.reject(e);
			});
		mainThread.close();
	});
	t.start();
	return p;
}

final class WorkerHttpClient : HttpClient
{
	this(Duration timeout, IConnection c)
	{
		super(timeout, new NullConnector(c));
	}

	Nullable!MonoTime whenTimeout() { return timer.when; }
}

final class Worker
{
private:
	enum State
	{
		none,     /// Worker process does not exist
	//	starting,
		running,  /// Idle or processing requests
		stopping, /// EOF has been sent, waiting for process to exit
	}
	State state;

	Request[] queue;
	IConnection c;
	WorkerHttpClient http;
	ulong sentRequests;
	// idleTask is running if (state == State.running && queue.length == 0)
	TimerTask idleTask;

	struct KillSchedule
	{
		MonoTime when;
		int signal;
	}
	KillSchedule[] killSchedule;
	TimerTask killTask;
	Pid pid;

	void start()
	{
		assert(state == State.none);
		auto pipes = pipeProcess(
			workerCommand,
			Redirect.stdin | Redirect.stdout,
		);
		this.pid = pipes.pid;
		c = new Duplex(
			new FileConnection(pipes.stdout.fileno.dup),
			new FileConnection(pipes.stdin.fileno.dup),
		);
		assert(c.state == ConnectionState.connected);
		http = new WorkerHttpClient(workerTimeout, c);
		http.keepAlive = true;
		http.pipelining = true;
		http.handleResponse = &onResponse;
		http.handleDisconnect = &onDisconnect;

		(() => pipes.pid.wait).threadAsync.then(&onExit);

		mainTimer.add(idleTask, now + maxIdleTime);

		state = State.running;
	}

	void stop()
	{
		assert(state == State.running);
		state = State.stopping;
		http.disconnect();
		if (idleTask.isWaiting())
			idleTask.cancel();
	}

	void onDisconnect(string reason, DisconnectType /*type*/)
	{
		assert(state == State.running || state == State.stopping);
		if (state != State.stopping)
		{
			stderr.writefln("clb: Worker sent EOF unexpectedly (%s)", reason);
			state = State.stopping; // Just wait for it to exit I guess
		}

		foreach (ref r; queue)
			sendResponse(r, null);
		queue = null;
		c = null;
		http = null;
		sentRequests = 0;
		if (idleTask.isWaiting())
			idleTask.cancel();

		assert(!killSchedule.length);
		foreach (rule; killRules)
			killSchedule ~= KillSchedule(now + rule.time, rule.signal);
		prodKill();
	}

	void onExit(int exitCode)
	{
		if (exitCode != 0)
			stderr.writefln("clb: Worker exited abnormally (exit code %d)", exitCode);

		final switch (state)
		{
			case State.none:
				assert(false);
			case State.running:
				stderr.writeln("clb: Worker exited unexpectedly");
				state = State.stopping;
				http.disconnect();
				break; // proceed to clean-up
			case State.stopping:
				break; // proceed to clean-up
		}

		assert(queue is null);
		assert(http is null);
		assert(state == State.stopping);
		state = State.none;
		assert(sentRequests == 0);
		assert(!idleTask.isWaiting());

		if (killSchedule.length)
		{
			killSchedule = null;
			killTask.cancel();
		}
		assert(!killTask.isWaiting());
		pid = null;

		prod();
	}

	void prodKill()
	{
		assert(!killTask.isWaiting());
		assert(pid);
		if (killSchedule.length)
			mainTimer.add(killTask, killSchedule[0].when);
	}

	void onKillSchedule(Timer /*timer*/, TimerTask /*timerTask*/)
	{
		assert(killSchedule.length);
		assert(pid);
		auto signal = killSchedule.shift().signal;
		stderr.writefln("clb: Killing worker PID %d with %d", pid.processID(), signal);
		pid.kill(signal);
		prodKill();
	}

	void sendResponse(ref Request r, HttpResponse res)
	{
		if (r.conn.connected)
		{
			if (res)
				r.conn.sendResponse(res);
			else // res is null (an error occurred)
			{
				if (retry)
				{
					(Request r) { // Copy the by-ref variable
						socketManager.onNextTick({
							enqueueRequest(r);
						});
					}(r);
				}
				else
				{
					res = new HttpResponse();
					res.setStatus(state == State.stopping
						? HttpStatusCode.ServiceUnavailable
						: HttpStatusCode.BadGateway);
					r.conn.sendResponse(res);
				}
			}
		}
	}

	void onIdle(Timer /*timer*/, TimerTask /*task*/)
	{
		stop();
	}

	void onResponse(HttpResponse res, string disconnectReason)
	{
		assert(queue.length, "Unexpected response");
		if (!res)
			stderr.writefln("clb: No response from worker: %s", disconnectReason);
		auto r = queue.queuePop();
		sendResponse(r, res);

		if (queue.length == 0 && state == State.running)
			mainTimer.add(idleTask, now + maxIdleTime);

		prod();
	}

	void prod()
	{
		if (.requestQueue.length &&
			queue.length < maxPipelining &&
			sentRequests < maxRequests)
		{
			auto ok = acceptRequest(.requestQueue.queuePop());
			assert(ok);
		}

		if (sentRequests == maxRequests &&
			queue.length == 0 &&
			state == State.running)
			stop();
	}

public:
	this()
	{
		idleTask = new TimerTask(&onIdle);
		killTask = new TimerTask(&onKillSchedule);
	}

	bool acceptRequest(ref Request r)
	{
		if (sentRequests >= maxRequests)
			return false;

		final switch (state)
		{
			case State.none:
				start();
				goto case State.running;
			case State.running:
				if (queue.length >= maxPipelining)
					return false;
				break; // proceed to accept request
			case State.stopping:
				return false;
		}

		if (!queue.length)
			idleTask.cancel();
		auto req = r.req;
		if (!retry)
			r.req = null; // We don't need to keep a copy any more.
		queue ~= r;
		req.headers["Connection"] = "keep-alive";
		http.request(req, false);
		sentRequests++;
		return true;
	}

	void shutdown()
	{
		final switch (state)
		{
			case State.none:
			case State.stopping:
				return;
			case State.running:
				stop();
		}
	}

	struct Status
	{
		State workerProcessState;
		Nullable!int pid;
		Nullable!ConnectionState workerConnectionState;
		ulong sentRequests;
		size_t inFlightRequests;
		Nullable!ConnectionState downstreamConnectionState;
		Nullable!Duration timeUntilTimeout;
		Nullable!Duration timeUntilIdle;
		Nullable!int nextKillSignal;
		Nullable!Duration timeUntilKill;
	}

	Status getStatus()
	{
		Nullable!T maybe(T)(bool cond, lazy T expr) { return cond ? Nullable!T(expr) : Nullable!T.init; }
		return Status(
			this.state,
			maybe(pid !is null, pid.processID()),
			maybe(c !is null, c.state),
			this.sentRequests,
			this.queue.length,
			maybe(queue.length > 0, queue[0].conn.conn.state),
			maybe(http !is null, http.whenTimeout).flatten().apply!(t => t - now),
			maybe(idleTask.isWaiting(), idleTask.when - now),
			maybe(killSchedule.length > 0, killSchedule[0].signal),
			maybe(killSchedule.length > 0, killSchedule[0].when - now),
		);
	}
}
Worker[] workers;

void createWorkers(uint concurrency)
{
	workers = new Worker[concurrency];
	foreach (ref worker; workers)
		worker = new Worker();
}

struct Request
{
	HttpRequest req;
	HttpServerConnection conn; /// Where to send the reply to
}

Request[] requestQueue;

void enqueueRequest(Request r)
{
	foreach (worker; workers)
		if (worker.acceptRequest(r))
			return;

	requestQueue ~= r;
}

enum statusHtmlRes = "/.well-known/clb/status.html";
enum statusJsonRes = "/.well-known/clb/status.json";

struct Status
{
	size_t queuedRequests;
	Worker.Status[] workerStatus;
}

Status getStatus()
{
	return Status(
		requestQueue.length,
		workers.map!(w => w.getStatus()).array,
	);
}

string identifierToHuman(string s) { s = s.splitByCamelCase.join(" "); if (s.length) s = toUpper(s[0]) ~ s[1..$]; return s; }

string toHTML(T)(T v)
{
	string s;
	static if (is(T : Nullable!U, U))
	{
		if (v.isNull())
			s ~= "-";
		else
			s ~= v.get().toHTML();
	}
	else
	static if (__traits(hasMember, T, "toString"))
		s ~= v.toString();
	else
	static if (is(T : U[], U) && is(U == struct))
	{
		s ~= `<table border="1">`;
		s ~= "<tr>";
		foreach (i, f; U.init.tupleof)
			s ~= "<th>" ~ __traits(identifier, U.tupleof[i]).identifierToHuman.encodeEntities ~ "</th>";
		s ~= "</tr>";
		foreach (ref row; v)
		{
			s ~= "<tr>";
			foreach (i, ref f; row.tupleof)
				s ~= "<td>" ~ f.toHTML() ~ "</td>";
			s ~= "</tr>";
		}
		s ~= "</table>";
	}
	else
	static if (is(T == struct))
	{
		s ~= "<dl>";
		foreach (i, ref f; v.tupleof)
		{
			s ~= "<dt>" ~ __traits(identifier, v.tupleof[i]).identifierToHuman.encodeEntities ~ "</td>";
			s ~= "<dd>" ~ f.toHTML() ~ "</td>";
		}
		s ~= "</dl>";
	}
	else
	static if (is(T : ulong))
		s ~= v.to!string;
	else
		static assert(false, "Can't convert " ~ T.stringof ~ " to HTML");
	return s;
}

HttpServer startServer(string socketPath, bool enableStatus)
{
	auto httpServer = new HttpServer;

	httpServer.handleRequest =
		(HttpRequest req, HttpServerConnection conn)
		{
			if (enableStatus && req.resource == statusHtmlRes)
			{
				auto r = new HttpResponse();
				r.setStatus(HttpStatusCode.OK);
				auto html = "<!doctype html>\n" ~ getStatus().toHTML();
				r.data = DataVec(Data(html.representation));
				r.headers["Content-Type"] = "text/html";
				return conn.sendResponse(r);
			}
			if (enableStatus && req.resource == statusJsonRes)
			{
				auto r = new HttpResponse();
				r.setStatus(HttpStatusCode.OK);
				auto json = getStatus().toJson();
				r.data = DataVec(Data(json.representation));
				r.headers["Content-Type"] = "application/json";
				return conn.sendResponse(r);
			}

			enqueueRequest(Request(req, conn));
		};

	socketPath.remove().collectException();

	AddressInfo ai;
	ai.family = AddressFamily.UNIX;
	ai.type = SocketType.STREAM;
	ai.address = new UnixAddress(socketPath);
	httpServer.listen([ai]);

	return httpServer;
}

version (Posix)
shared static this()
{
	import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;
	signal(SIGPIPE, SIG_IGN);
}

@(`Simple HTTP load balancer with auto-scaling.`)
void clb(
	Parameter!(string,
		"Program to start one worker instance.\n" ~
		"Workers receive requests over standard input, " ~
		"and send responses in the same order over standard output. " ~
		"EOF on stdin indicates a request to shut down.",
		"COMMAND",
	) command,
	Parameter!(string[],
		"Program arguments.",
		"ARGS",
	) args = null,
	Option!(string,
		"Address (path to UNIX socket) to listen on.",
		"ADDRESS"
	) listen = null,
	Option!(uint,
		"How many workers may run at the same time.\n" ~
		"This includes workers which are starting or stopping.",
		"N", 'j',
	) concurrency = 0,
	Option!(size_t,
		"How many requests to send to workers without waiting for a response first.",
		"N",
	) pipelining = 1,
	Option!(ulong,
		"How many requests a worker may handle before it is cycled.",
		"N",
	) maxRequests = ulong.max,
	Option!(ulong,
		"Stop workers that have not received a request for this duration.",
		"SECONDS",
	) maxIdle = 60,
	Option!(ulong,
		"Stop workers/requests that have not responded to a request for this duration.",
		"SECONDS",
	) timeout = 1.weeks.total!"seconds",
	Switch!(
		"Retry requests until they succeed, instead of returning HTTP 502. " ~
		"Suitable for stateless workers.",
	) retry = false,
	Option!(string[],
		"Add a kill rule. " ~
		"If the worker does not exit within SECONDS after EOF is sent, send SIGNAL to the process. " ~
		"The signal is sent only to the top-level process (COMMAND).",
		"SECONDS:SIGNAL",
	) kill = null,
	Switch!(
		"Enable a status page at " ~ statusHtmlRes ~ " and .json.",
	) enableStatus = false,
)
{
	if (concurrency == 0)
		concurrency = totalCPUs;

	enforce(listen.length, "Listen address not specified");
	enforce(concurrency > 0, "Must have at least one worker");
	enforce(pipelining > 0, "Must allow at least one in-flight request");
	enforce(maxRequests > 0, "Must allow at least one request per worker");

	.workerCommand = command ~ args;
	.maxPipelining = pipelining;
	.maxRequests = maxRequests;
	.maxIdleTime = maxIdle.seconds;
	.workerTimeout = timeout.seconds;
	.retry = retry;
	foreach (rule; kill)
	{
		auto parts = rule.findSplit(":").enforce("Bad kill rule");
		killRules ~= KillRule(parts[0].to!ulong.seconds, parts[2].parseSignalName);
	}
	killRules.sort!((a, b) => a.time < b.time, SwapStrategy.stable)();

	createWorkers(concurrency);

	auto server = startServer(listen, enableStatus);

	addShutdownHandler((reason) {
		.retry = false;
		server.close();
		foreach (worker; workers)
			worker.shutdown();
		workers = null;
		foreach (ref r; requestQueue)
			if (r.conn.connected)
			{
				auto res = new HttpResponse();
				res.setStatus(HttpStatusCode.ServiceUnavailable);
				res.headers["Connection"] = "close";
				r.conn.sendResponse(res);
				r.conn.conn.disconnect();
			}
		requestQueue = null;
	});

	socketManager.loop();
}

int parseSignalName(string s)
{
	version (Posix)
	{
		if (isNumeric(s))
			return s.to!int;
		switch (s)
		{
			import core.sys.posix.signal;
			case "SIGHUP": case "HUP": return SIGHUP;
			case "SIGINT": case "INT": return SIGINT;
			case "SIGQUIT": case "QUIT": return SIGQUIT;
			case "SIGILL": case "ILL": return SIGILL;
			case "SIGTRAP": case "TRAP": return SIGTRAP;
			case "SIGABRT": case "ABRT": return SIGABRT;
			// case "SIGIOT": case "IOT": return SIGIOT;
			case "SIGBUS": case "BUS": return SIGBUS;
			// case "SIGEMT": case "EMT": return SIGEMT;
			case "SIGFPE": case "FPE": return SIGFPE;
			case "SIGKILL": case "KILL": return SIGKILL;
			case "SIGUSR1": case "USR1": return SIGUSR1;
			case "SIGSEGV": case "SEGV": return SIGSEGV;
			case "SIGUSR2": case "USR2": return SIGUSR2;
			case "SIGPIPE": case "PIPE": return SIGPIPE;
			case "SIGALRM": case "ALRM": return SIGALRM;
			case "SIGTERM": case "TERM": return SIGTERM;
			// case "SIGSTKFLT": case "STKFLT": return SIGSTKFLT;
			case "SIGCHLD": case "CHLD": return SIGCHLD;
			// case "SIGCLD": case "CLD": return SIGCLD;
			case "SIGCONT": case "CONT": return SIGCONT;
			case "SIGSTOP": case "STOP": return SIGSTOP;
			case "SIGTSTP": case "TSTP": return SIGTSTP;
			case "SIGTTIN": case "TTIN": return SIGTTIN;
			case "SIGTTOU": case "TTOU": return SIGTTOU;
			case "SIGURG": case "URG": return SIGURG;
			case "SIGXCPU": case "XCPU": return SIGXCPU;
			case "SIGXFSZ": case "XFSZ": return SIGXFSZ;
			case "SIGVTALRM": case "VTALRM": return SIGVTALRM;
			case "SIGPROF": case "PROF": return SIGPROF;
			// case "SIGWINCH": case "WINCH": return SIGWINCH;
			// case "SIGIO": case "IO": return SIGIO;
			case "SIGPOLL": case "POLL": return SIGPOLL;
			// case "SIGPWR": case "PWR": return SIGPWR;
			// case "SIGINFO": case "INFO": return SIGINFO;
			// case "SIGLOST": case "LOST": return SIGLOST;
			case "SIGSYS": case "SYS": return SIGSYS;
			// case "SIGUNUSED": case "UNUSED": return SIGUNUSED;
			default: throw new Exception("Unknown signal: " ~ s);
		}
	}
	else
	version (Windows)
	{
		enforce(s.skipOver("TerminateProcess:"), "Windows kill rules have the syntax SECONDS:TerminateProcess:EXITCODE");
		return s.to!uint;
	}
	else
		static assert(false);
}

mixin main!(funopt!(clb, FunOptConfig([std.getopt.config.stopOnFirstNonOption])));

// Basic test
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 1.weeks;
	.retry = false;
	.killRules = [];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	bool ok;
	auto c = new HttpClient(1.seconds, new UnixConnector(listenAddr));
	c.handleResponse = (HttpResponse r, string disconnectReason)
	{
		assert(r, disconnectReason);
		r.getContent().enter((contents) {
			ok = contents == "OK";
		});
		s.close();
		foreach (b; workers) b.shutdown();
	};
	c.request(new HttpRequest("http://server/"));

	socketManager.loop();
	assert(ok);
}

// Load-balancing test
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		sleep 0.5
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 1.weeks;
	.retry = false;
	.killRules = [];

	createWorkers(3);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	foreach (n; 0 .. 3)
	{
		auto c = new HttpClient(1.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
		};
		c.request(new HttpRequest("http://server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
}

// Test multiple requests per worker
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		sleep 0.5
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 1.weeks;
	.retry = false;
	.killRules = [];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	foreach (n; 0 .. 3)
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
		};
		c.request(new HttpRequest("http://server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 1);
}

// Test pipelining
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
for n in $(seq 3)
do
	while IFS= read -r line
	do
		if [[ "$line" == $'\r' ]]
		then
			break
		fi
	done
done
for n in $(seq 3)
do
	printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
done
EOF"];
	.maxPipelining = 3;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 1.weeks;
	.retry = false;
	.killRules = [];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	foreach (n; 0 .. 3)
	{
		auto c = new HttpClient(1.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
		};
		c.request(new HttpRequest("http://server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 1);
}

// Test --max-requests
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		sleep 0.5
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = 1;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 1.weeks;
	.retry = false;
	.killRules = [];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	foreach (n; 0 .. 3)
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
		};
		c.request(new HttpRequest("http://server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
}

// Test --max-idle
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 500.msecs;
	.workerTimeout = 1.weeks;
	.retry = false;
	.killRules = [];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	void sendRequest()
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
			else
				setTimeout(&sendRequest, 1.seconds);
		};
		c.request(new HttpRequest("http://server/"));
	}
	sendRequest();

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
}

// Test --timeout
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
# Buggy worker that stops replying after the first reply
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
		sleep 1  # Still exit after some time to allow the unittest to terminate
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 500.msecs;
	.retry = false;
	.killRules = [];

	createWorkers(3);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	void sendRequest()
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			pids ~= r.headers.get("X-PID", null);
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
			else
				sendRequest();
		};
		c.request(new HttpRequest("http://server/"));
	}
	sendRequest();

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
	assert(pids.canFind(null));  // One request was lost
}

// Test --retry
unittest
{
	.workerCommand = ["/bin/bash", "-c", q"EOF
# Buggy worker that stops replying after the first reply
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
		sleep 1  # Still exit after some time to allow the unittest to terminate
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 500.msecs;
	.retry = true;
	.killRules = [];

	createWorkers(3);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	void sendRequest()
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			pids ~= r.headers.get("X-PID", null);
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
			else
				sendRequest();
		};
		c.request(new HttpRequest("http://server/"));
	}
	sendRequest();

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
	assert(!pids.canFind(null));  // No requests were lost because of --retry
}

// Test --kill
version (Posix)
unittest
{
	import core.sys.posix.signal : SIGTERM;
	.workerCommand = ["/bin/bash", "-c", q"EOF
# Buggy worker that stops replying after the first reply
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
		sleep infinity
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 500.msecs;
	.retry = true;
	.killRules = [
		KillRule(500.msecs, SIGTERM),
	];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	foreach (n; 0 .. 3)
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
		};
		c.request(new HttpRequest("http://server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
	assert(!pids.canFind(null));  // No requests were lost because of --retry
}

// Test 2x --kill
version (Posix)
unittest
{
	import core.sys.posix.signal : SIGTERM, SIGKILL;
	.workerCommand = ["/bin/bash", "-c", q"EOF
# Buggy worker that stops replying after the first reply, and ignores SIGTERM
trap '' TERM INT
while IFS= read -r line
do
	if [[ "$line" == $'\r' ]]
	then
		printf 'HTTP/1.1 200 OK\r\nX-PID: %d\r\nContent-Length: 2\r\n\r\nOK' "$$"
		sleep infinity
	fi
done
EOF"];
	.maxPipelining = 1;
	.maxRequests = ulong.max;
	.maxIdleTime = 60.seconds;
	.workerTimeout = 500.msecs;
	.retry = true;
	.killRules = [
		KillRule(250.msecs, SIGTERM),
		KillRule(500.msecs, SIGKILL),
	];

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr, true);
	scope(exit) remove(listenAddr);

	string[] pids;

	foreach (n; 0 .. 3)
	{
		auto c = new HttpClient(5.seconds, new UnixConnector(listenAddr));
		c.handleResponse = (HttpResponse r, string disconnectReason)
		{
			assert(r, disconnectReason);
			r.getContent().enter((contents) {
				assert(contents == "OK");
			});
			pids ~= r.headers["X-PID"];
			if (pids.length == 3)
			{
				s.close();
				foreach (b; workers) b.shutdown();
			}
		};
		c.request(new HttpRequest("http://server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
	assert(!pids.canFind(null));  // No requests were lost because of --retry
}
