#+build freestanding arm32

package matchbox

/*
	Util
	====
	This file contains utility procedures +
	procedures I couldn't thematically find a spot for
*/

import "core:fmt"
import "o3dx/ctru"


Asset_Type :: enum {
	IMAGE,
	AUDIO,
}

/*
	prints a line to the console
		- Needed as fmt does not work on freestanding
	On windows, called fmt.println()
*/

print :: proc(args: ..any) {
	buf: [256]u8 // zeroed, so it is already null-terminated
	fmt.bprintln(buf[:255], ..args)
	ctru.printf("%s", cstring(&buf[0]))
}

/*Joins the parts into buf and returns a null-terminated path. The caller owns buf, so it must outlive the returned cstring*/
build_path :: proc(buf: []u8, parts: ..string) -> (path: cstring, ok: bool) {
	n := 0
	for part in parts {
		if n + len(part) >= len(buf) do return nil, false // leave room for the terminator
		for i in 0..<len(part) do buf[n + i] = part[i]
		n += len(part)
	}
	buf[n] = 0
	return cstring(raw_data(buf)), true
}

/* "toyota.png" -> "toyota". Cuts at the LAST '.', and a name without a dot is returned unchanged */
strip_extension :: proc(name: string) -> string {
	for i := len(name) - 1; i >= 0; i -= 1 {
		if name[i] == '.' do return name[:i]
	}
	return name
}

/*3DS equivalent of os.is_file: true if the file can be opened*/
file_exists :: proc(path: cstring) -> bool {
	file := ctru.fopen(path, "rb")
	if file == nil do return false
	ctru.fclose(file)
	return true
}

/*Returns the romfs path for an asset. The build step has already chosen shared vs 3DS-specific*/
get_asset :: proc(buf: []u8, filename: string, asset_type: Asset_Type) -> (path: cstring, ok: bool) {
	switch asset_type {
	case .IMAGE:
		return build_path(buf, mbi.asset_path, "gfx/", strip_extension(filename), ".t3x")
	case .AUDIO:
		return build_path(buf, mbi.asset_path, "audio/", filename) // untested; mp3 becomes .wav in the build
	}
	return nil, false
}

/* |===============|
   |PROCEDURE GROUP|
   |===============|
*/

/*Procedure group that will call the appropiate
destroy procedure based on arugment passed*/
destroy :: proc {
	destroy_sprite,
	destroy_audio,
}
