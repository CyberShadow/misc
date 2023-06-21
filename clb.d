/// Simple HTTP load balancer with auto-scaling.
module clb;

import core.time;

import std.algorithm.searching;
import std.exception : collectException, enforce;
import std.file : remove;
import std.parallelism : totalCPUs;
import std.process;
import std.socket : AddressInfo, AddressFamily, SocketType, UnixAddress;
import std.stdio : stderr;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.server;
import ae.net.shutdown;
import ae.utils.array;
import ae.utils.funopt;
import ae.utils.main;

string[] workerCommand;
size_t maxPipelining;
ulong maxRequests;
Duration workerTimeout = 1.weeks;

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

	HttpServerConnection[] queue;
	HttpClient http;
	ulong sentRequests;

	void start()
	{
		assert(state == State.none);
		auto pipes = pipeProcess(
			workerCommand,
			Redirect.stdin | Redirect.stdout,
		);
		// this.pid = pipes.pid;
		auto c = new Duplex(
			new FileConnection(pipes.stdout.fileno.dup),
			new FileConnection(pipes.stdin.fileno.dup),
		);
		assert(c.state == ConnectionState.connected);
		http = new HttpClient(workerTimeout, new NullConnector(c));
		http.keepAlive = true;
		http.pipelining = true;
		http.handleResponse = &onResponse;
		http.handleDisconnect = &onDisconnect;

		(() => pipes.pid.wait).threadAsync.then(&onExit);

		state = State.running;
	}

	void stop()
	{
		assert(state == State.running);
		state = State.stopping;
		http.disconnect();
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		assert(state == State.running || state == State.stopping);
		if (state != State.stopping)
		{
			stderr.writefln("Worker sent EOF unexpectedly (%s)", reason);
			state = State.stopping; // Just wait for it to exit I guess
		}
	}

	void onExit(int exitCode)
	{
		if (exitCode != 0)
			stderr.writefln("Worker exited abnormally (exit code %d)", exitCode);

		final switch (state)
		{
			case State.none:
				assert(false);
			case State.running:
				stderr.writeln("Worker exited unexpectedly");
				state = State.stopping;
				http.disconnect();
				break; // proceed to clean-up
			case State.stopping:
				break; // proceed to clean-up
		}

		foreach (c; queue)
		{
			auto r = new HttpResponse();
			r.setStatus(HttpStatusCode.BadGateway);
			c.sendResponse(r);
		}
		queue = null;
		http = null;
		state = State.none;
		sentRequests = 0;

		prod();
	}

	void onResponse(HttpResponse r, string disconnectReason)
	{
		assert(queue.length, "Unexpected response");
		enforce(r, "No response from worker: " ~ disconnectReason);
		auto conn = queue.queuePop();
		if (conn.connected)
			conn.sendResponse(r);

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

		queue ~= r.conn;
		r.req.headers["Connection"] = "keep-alive";
		http.request(r.req, false);
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

HttpServer startServer(string socketPath)
{
	auto httpServer = new HttpServer;

	httpServer.handleRequest =
		(HttpRequest req, HttpServerConnection conn)
		{
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

void clb(
	Parameter!(string,
		"Program to start one worker instance.\n" ~
		"Workers receive one request at a time over standard input, " ~
		"and send the response over standard output.\n" ~
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
		"How many workers may run at the same time.",
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
	// Option!(ulong,
	// 	"Stop workers that have not received a request for this duration.",
	// 	"SECONDS",
	// ) maxIdle = 60,
	// Option!(uint,
	// 	"Give up on workers/requests that have not responded to a request for this duration.",
	// 	"SECONDS",
	// ) timeout = 1.weeks.total!"seconds",
)
{
	enforce(listen.length, "Listen address not specified");
	enforce(concurrency > 0, "Must have at least one worker");
	enforce(pipelining > 0, "Must allow at least one in-flight request");
	enforce(maxRequests > 0, "Must allow at least one request per worker");

	.workerCommand = command ~ args;
	.maxPipelining = pipelining;
	.maxRequests = maxRequests;

	if (concurrency == 0)
		concurrency = totalCPUs;
	createWorkers(concurrency);

	auto server = startServer(listen);

	addShutdownHandler((reason) {
		server.close();
		foreach (worker; workers)
			worker.shutdown();
	});

	socketManager.loop();
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

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr);
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
	c.request(new HttpRequest("http:/server/"));

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

	createWorkers(3);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr);
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
		c.request(new HttpRequest("http:/server/"));
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

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr);
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
		c.request(new HttpRequest("http:/server/"));
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

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr);
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
		c.request(new HttpRequest("http:/server/"));
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

	createWorkers(1);
	auto listenAddr = "clb-test";
	auto s = startServer(listenAddr);
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
		c.request(new HttpRequest("http:/server/"));
	}

	socketManager.loop();

	import std.algorithm.sorting : sort;
	import std.algorithm.iteration : uniq;
	import std.range.primitives : walkLength;
	assert(pids.sort.uniq.walkLength == 3);
}
