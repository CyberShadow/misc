import std.exception;
import std.file;
import std.stdio : File, writeln;
import std.string;

import core.sys.posix.fcntl;
import core.sys.posix.termios;
import core.sys.posix.unistd;
import core.thread;

import ae.utils.funopt;
import ae.utils.main;

const serialPath = "/dev/serial/by-id/usb-Prolific_Technology_Inc._USB-Serial_Controller-if00-port0";

int serial;
File lock;
bool verbose;

void sendCommand(string command)
{
	assert(command.length == 8, "Invalid command length");
	command ~= "\r";
	if (verbose) writeln("> ", [command]);
	auto result = write(serial, command.ptr, command.length);
	errnoEnforce(result == command.length);
}

string readAnswer()
{
	string answer;
	while (true)
	{
		char c;
		errnoEnforce(read(serial, &c, c.sizeof) == 1, "Read failed");
		answer ~= c;
		if (c == '\n')
			break;
	}

	if (verbose) writeln("< ", [answer]);
	return answer.chomp();
}

string readValue(string name)
{
	assert(name.length == 4, "Invalid name length");
	sendCommand("%s????".format(name));
	auto answer = readAnswer();
	enforce(answer != "ERR", "Reading value failed: " ~ name);
	return answer;
}

void writeValue(string name, string value)
{
	assert(name.length == 4, "Invalid name length");
	assert(value.length <= 4, "Invalid value length");
	sendCommand("%s%4s".format(name, value));
	auto answer = readAnswer();
	if (answer == "WAIT")
		answer = readAnswer();
	enforce(answer != "ERR", "Writing value failed: " ~ name);
	enforce(answer == "OK", "Unexpected reply when writing value " ~ name ~ ": " ~ answer);
}

void initialize()
{
	serial = open(serialPath.ptr, O_RDWR /*| O_NONBLOCK*/);
	lock.fdopen(serial);
	lock.lock();

	termios mode;
	mode.c_iflag=0;
	mode.c_oflag=0;
	mode.c_cflag=CS8|CREAD|CLOCAL;           // 8n1, see termios.h for more information
	mode.c_lflag=0;
	mode.c_cc[VMIN]=1;
	mode.c_cc[VTIME]=1;
	errnoEnforce(cfsetispeed(&mode, B38400) == 0);
	errnoEnforce(cfsetospeed(&mode, B38400) == 0);

	errnoEnforce(tcsetattr(serial, TCSANOW, &mode) == 0);
}

struct PQ321Q
{
static:
	void read(string name)
	{
		writeln(readValue(name));
	}

	void write(string name, string value)
	{
		writeValue(name, value);
	}

}

//  cs8 -parenb -cstopb -ixon
void pq321q(bool verbose, string command, string[] commandArgs)
{
	.verbose = verbose;
	initialize();

	funoptDispatch!PQ321Q([thisExePath, command] ~ commandArgs);

	// writeValue("VOLM", "30");
	// readValue("VOLM");
	// foreach (n; 0..2)
	//	try
	//		readValue("VOLM");
	//	catch {}
	// //foreach (n; 0..50)
	// while (true)
	//	readAnswer();
}

mixin main!(funopt!pq321q);
