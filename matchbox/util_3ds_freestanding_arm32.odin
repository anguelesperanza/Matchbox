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
import "o3dx/o3dx"

when !VITA {

	Asset_Type :: enum {
		IMAGE,
		AUDIO,
	}

	/*
		Prints a line on the bottom screen (drawn at render_end, over the game; see
		bottom_screen_3ds_freestanding_arm32.odin) and to the emulator's log (Luma3DS's
		debugger on hardware). The log matters: it is the only copy a test run can read back
		without looking at the screen. Formats on the stack, 1024 bytes at most
	*/
	print :: proc(args: ..any) {
		buffer:[o3dx.PRINT_BUFFER_SIZE]u8
		text := fmt.bprint(buffer[:], ..args, sep = " ")
		o3dx.write(text)
		o3dx.write("\n")
		add_print_lines(text)
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

	/*
		Reads a whole file into memory the caller deletes, as 32-bit words: what the shader
		binary parser takes, which also gives it the 4-byte alignment it needs. Empty when the
		file cannot be read
	*/
	read_file_words :: proc(path:cstring) -> []u32 {
		file := ctru.fopen(path, "rb")
		if file == nil do return nil
		defer ctru.fclose(file)

		ctru.fseek(file, 0, 2) // SEEK_END
		size := int(ctru.ftell(file))
		ctru.fseek(file, 0, 0) // SEEK_SET
		if size <= 0 do return nil

		words := make([]u32, (size + 3) / 4)
		if int(ctru.fread(raw_data(words), 1, uint(size), file)) != size {
			delete(words)
			return nil
		}
		return words
	}

	/*Reads a whole file into memory the caller deletes. nil when the file cannot be read*/
	read_file_bytes :: proc(path:cstring) -> []u8 {
		file := ctru.fopen(path, "rb")
		if file == nil do return nil
		defer ctru.fclose(file)

		ctru.fseek(file, 0, 2) // SEEK_END
		size := int(ctru.ftell(file))
		ctru.fseek(file, 0, 0) // SEEK_SET
		if size <= 0 do return nil

		bytes := make([]u8, size)
		if int(ctru.fread(raw_data(bytes), 1, uint(size), file)) != size {
			delete(bytes)
			return nil
		}
		return bytes
	}

	/*3DS equivalent of os.is_file: true if the file can be opened*/
	file_exists :: proc(path: cstring) -> bool {
		file := ctru.fopen(path, "rb")
		if file == nil do return false
		ctru.fclose(file)
		return true
	}

	/*
		Returns the romfs path for an asset. The build step has already chosen shared vs
		3DS-specific. Subfolders are kept: 3ds_build.bat writes each image's .t3x at its path
		under assets/images, so `filename` means the same file here as on PC (D4)
	*/
	get_asset :: proc(buffer: []u8, filename: string, asset_type: Asset_Type) -> (path: cstring, ok: bool) {
		switch asset_type {
		case .IMAGE:
			return build_path(buffer, mbi.asset_path, "gfx/", strip_extension(filename), ".t3x")
		case .AUDIO:
			return build_path(buffer, mbi.asset_path, "audio/", filename) // untested; mp3 becomes .wav in the build
		}
		return nil, false
	}
}
