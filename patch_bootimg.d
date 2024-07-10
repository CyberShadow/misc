#!/usr/bin/env dub
/+ dub.sdl:
 dependency "ae" version="==0.0.3569"
+/

/// Patch an Android boot.img file.

module patch_bootimg;

import core.stdc.stdint;

import std.conv;
import std.exception;
import std.file;
import std.stdio;

import ae.utils.funopt;
import ae.utils.main;

// from bootimg.h

enum BOOT_MAGIC = "ANDROID!";
enum BOOT_MAGIC_SIZE = 8;
enum BOOT_NAME_SIZE = 16;
enum BOOT_ARGS_SIZE = 512;
enum BOOT_EXTRA_ARGS_SIZE = 1024;

align(1)
struct boot_img_hdr
{
align(1):

    char[BOOT_MAGIC_SIZE] magic;

    uint32_t kernel_size;  /* size in bytes */
    uint32_t kernel_addr;  /* physical load addr */

    uint32_t ramdisk_size; /* size in bytes */
    uint32_t ramdisk_addr; /* physical load addr */

    uint32_t second_size;  /* size in bytes */
    uint32_t second_addr;  /* physical load addr */

    uint32_t tags_addr;    /* physical addr for kernel tags */
    uint32_t page_size;    /* flash page size we assume */
    uint32_t unused;       /* reserved for future expansion: MUST be 0 */

    /* operating system version and security patch level; for
     * version "A.B.C" and patch level "Y-M-D":
     * ver = A << 14 | B << 7 | C         (7 bits for each of A, B, C)
     * lvl = ((Y - 2000) & 127) << 4 | M  (7 bits for Y, 4 bits for M)
     * os_version = ver << 11 | lvl */
    uint32_t os_version;

    char[BOOT_NAME_SIZE] name; /* asciiz product name */

    char[BOOT_ARGS_SIZE] cmdline;

    uint32_t[8] id; /* timestamp / checksum / sha1 / etc */

    /* Supplemental command line data; kept here to maintain
     * binary compatibility with older versions of mkbootimg */
    char[BOOT_EXTRA_ARGS_SIZE] extra_cmdline;
}

mixin main!(funopt!patch_bootimg);

void patch_bootimg(string bootImg, string output = null,
	string kernel = null, string ramdisk = null, string second = null,
	string saveKernel = null, string saveRamdisk = null, string saveSecond = null,
)
{
	auto bytes = read(bootImg);
	enforce(bytes.length > boot_img_hdr.sizeof);
	auto header = cast(boot_img_hdr*)bytes.ptr;
	enforce(boot_img_hdr.sizeof <= header.page_size);
	enforce(bytes.length >= header.page_size);
	auto headerBytes = bytes[0..header.page_size];

	foreach (i, f; (*header).tupleof)
		writeln(__traits(identifier, boot_img_hdr.tupleof[i]), ": ", f);

	size_t bytesToPages(size_t bytes) { return (bytes + header.page_size - 1) / header.page_size; }
	size_t pagesToBytes(size_t pages) { return pages * header.page_size; }

	auto currentPage = 1;

	void[] slurpSection(uint32_t sizeBytes)
	{
		auto start = pagesToBytes(currentPage);
		auto data = bytes[start .. start + sizeBytes];
		auto sizePages = bytesToPages(sizeBytes);
		currentPage += sizePages;
		return data;
	}

	auto kernelBytes = slurpSection(header.kernel_size);
	auto ramdiskBytes = slurpSection(header.ramdisk_size);
	auto secondBytes = slurpSection(header.second_size);
	auto remainderBytes = bytes[pagesToBytes(currentPage) .. $];

	if (saveKernel)
		std.file.write(saveKernel, kernelBytes);
	if (saveRamdisk)
		std.file.write(saveRamdisk, ramdiskBytes);
	if (saveSecond)
		std.file.write(saveSecond, secondBytes);

	if (kernel)
		kernelBytes = read(kernel);
	if (ramdisk)
		ramdiskBytes = read(ramdisk);
	if (second)
		secondBytes = read(second);

	bytes = headerBytes;

	void barfSection(void[] data, ref uint32_t headerField)
	{
		headerField = data.length.to!uint32_t;
		data.length = pagesToBytes(bytesToPages(data.length));
		bytes ~= data;
	}

	barfSection(kernelBytes, header.kernel_size);
	barfSection(ramdiskBytes, header.ramdisk_size);
	barfSection(secondBytes, header.second_size);
	bytes ~= remainderBytes;

	if (output)
	{
		std.file.write(output, bytes);
		stderr.writefln("%s written!", output);
	}
}
