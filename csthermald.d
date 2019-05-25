/**
   Very simple CPU thermal management daemon.

   Example configuration:

   speedMin = 20
   speedMax = 100
   speedStep = 5

   interval = 1s

   [zones.acpitz]
   type = acpitz
   tempMin = 40000
   tempMax = 47000

   [zones.x86_pkg_temp]
   type = x86_pkg_temp
   tempMin = 40000
   tempMax = 55000
   runningAverage = 2
*/

import core.thread;

import std.algorithm.comparison;
import std.algorithm.mutation;
import std.conv;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.stdio;
import std.string;

import ae.utils.funopt;
import ae.utils.main;
import ae.utils.sini;
import ae.utils.time.parsedur;

struct Config
{
	struct Zone
	{
		string type;
		int tempMin, tempMax;
		int runningAverage = 1;
	}
	Zone[string] zones;

	int speedMin = 20;
	int speedMax = 100;
	int speedStep = 5;

	string interval = "1s";
}

void csthermald(string configFile = "/etc/csthermald.ini")
{
	auto config = loadIni!Config(configFile);

	auto interval = parseDuration(config.interval);

	static struct Zone
	{
		Config.Zone config;
		string tempPath;
		int[] values;
		long runningSum;
	}
	Zone[] zones;

	foreach (configZone; config.zones)
	{
		Zone zone;

		foreach (d; dirEntries("/sys/class/thermal", "thermal_zone*", SpanMode.shallow))
			if (d.buildPath("type").readText.strip == configZone.type)
			{
				zone.tempPath = d.buildPath("temp");
				break;
			}

		enforce(zone.tempPath, "Can't find thermal zone with type: %s".format(configZone.type));
		zone.config = configZone;
		zones ~= zone;
	}
	enforce(zones.length, "No zones configured");

	enum speedPath = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
	long lastSpeed = speedPath.readInt;

	while (true)
	{
		long factor = long.min;
		enum factorMult = 1000;
		foreach (ref zone; zones)
		{
			auto temp = zone.tempPath.readInt;
			if (zone.values.length < zone.config.runningAverage)
				zone.values ~= temp;
			else
			{
				zone.runningSum -= zone.values[0];
				zone.values.remove(0);
				zone.values[$-1] = temp; // FIXME, use a cyclic buffer instead
			}
			zone.runningSum += temp;

			auto avgTemp = zone.runningSum / cast(int)zone.values.length;
			auto zoneFactor = factorMult * (avgTemp - zone.config.tempMin) / (zone.config.tempMax - zone.config.tempMin);
			if (factor < zoneFactor)
				factor = zoneFactor;

			writef("%s: %d [avg: %d] m°C -> %3d%% | ", zone.config.type, zone.values[$-1], avgTemp, 100 * zoneFactor / factorMult);
		}

		auto speed = config.speedMax - (config.speedMax - config.speedMin) * factor / factorMult;
		auto speedClamped = speed.clamp(config.speedMin, min(config.speedMax, lastSpeed + config.speedStep));
		writefln("Speed %3d%% (clamped to %3d%%)", speed, speedClamped);
		std.file.write(speedPath, speedClamped.text);
		lastSpeed = speedClamped;
		Thread.sleep(interval);
	}
}

int readInt(string path) { return readText(path).strip.to!int; }

mixin main!(funopt!csthermald);
