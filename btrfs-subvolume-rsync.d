/// Recursively clone (send/receive) all btrfs subvolumes under a path.
module btrfs_subvolume_rsync;

// TODO: detect parents
// TODO: unify with btrfs-snapshot-archive and support SSH

import std.algorithm.iteration;
import std.array;
import std.exception;
import std.file;
import std.format;
import std.path;
import std.process;
import std.stdio;
import std.string;

import ae.sys.cmd;
import ae.sys.file;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.path;

void btrfsSubvolumeRsync(/*bool pv,*/ string srcRoot, string dstRoot)
{
	enum pv = true;
	auto srcMount = getPathMountInfo(srcRoot);
	enforce(srcMount.vfstype == "btrfs",
		format("Mount point of %s is %s and has FS %s, not btrfs", srcRoot, srcMount.file, srcMount.vfstype));
	auto dstMount = getPathMountInfo(dstRoot);
	enforce(dstMount.vfstype == "btrfs",
		format("Mount point of %s is %s and has FS %s, not btrfs", dstRoot, dstMount.file, dstMount.vfstype));

	auto subvolumes = query(["btrfs", "subvolume", "list", srcMount.file])
		.splitLines
		.map!(line => line.split(" ")[8..$].join(" "))
		.array;

	auto srcSubPath = relativePath(srcRoot, srcMount.file);
	foreach (subvolume; subvolumes)
	{
		if (!subvolume.pathStartsWith(srcSubPath))
			continue;
		auto srcAbsPath = srcMount.file.buildPath(subvolume);
		auto relPath = relativePath(srcAbsPath, srcRoot.absolutePath);
		auto dstAbsPath = buildPath(dstRoot, relPath);
		auto dstTarget = dstAbsPath.dirName;
		if (!dstTarget.exists)
		{
			stderr.writeln("Creating " , dstTarget);
			dstTarget.mkdirRecurse;
		}

		enforce(!dstAbsPath.exists, "Destination subvolume already exists: " ~ dstAbsPath);

		stderr.writefln("Sending %s to %s", srcAbsPath, dstTarget.includeTrailingPathSeparator);

		auto btrfsPipe = pipe();
		File readEnd, writeEnd;
		Pid pvPid;

		if (pv)
		{
			auto pvPipe = pipe();
			pvPid = spawnProcess(["pv"], btrfsPipe.readEnd, pvPipe.writeEnd);
			writeEnd = btrfsPipe.writeEnd;
			readEnd = pvPipe.readEnd;
		}
		else
		{
			readEnd = btrfsPipe.readEnd;
			writeEnd = btrfsPipe.writeEnd;
		}

		auto send = spawnProcess(["btrfs", "send", srcAbsPath], stdin, writeEnd);
		auto receive = spawnProcess(["btrfs", "receive", dstTarget], readEnd);
		enforce(send.wait() == 0, "btrfs-send failed");
		enforce(receive.wait() == 0, "btrfs-send failed");
		if (pv)
			enforce(pvPid.wait() == 0, "pv failed");
	}
}

mixin main!(funopt!btrfsSubvolumeRsync);
