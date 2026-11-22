#+build freestanding arm32

package matchbox

/*
	Util
	====
	This file contains utility procedures +
	procedures I couldn't thematically find a spot for
*/

import "o3dx/ctru"
import "o3dx/o3dx"

when !VITA {

	Asset_Type :: enum {
		IMAGE,
		AUDIO,
	}

	/*
		Prints a line to the bottom screen's console and to the emulator's log (Luma3DS's
		debugger on hardware). The log matters: it is the only output a test run can read
		back, and the console is gone once the bottom screen draws. Formats on the stack,
		1024 bytes at most; longer lines are cut off
	*/
	print :: proc(args: ..any) {
		o3dx.println(..args)
	}

	/*Joins the parts into buffer and returns a null-terminated path. The caller owns buffer, so it must outlive the returned cstring*/
	build_path :: proc(buffer: []u8, parts: ..string) -> (path: cstring, ok: bool) {
		n := 0
		for part in parts {
			if n + len(part) >= len(buffer) do return nil, false // leave room for the terminator
			for i in 0..<len(part) do buffer[n + i] = part[i]
			n += len(part)
		}
		buffer[n] = 0
		return cstring(raw_data(buffer)), true
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
	get_asset :: proc(buffer: []u8, filename: string, asset_type: Asset_Type) -> (path: cstring, ok: bool) {
		switch asset_type {
		case .IMAGE:
			return build_path(buffer, mbi.asset_path, "gfx/", strip_extension(filename), ".t3x")
		case .AUDIO:
			return build_path(buffer, mbi.asset_path, "audio/", filename) // untested; mp3 becomes .wav in the build
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
		destroy_audio,
	}
}
