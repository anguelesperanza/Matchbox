#+build freestanding arm32

package matchbox

/*
	Util -- Vita
	============
	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "core:fmt"

import "vito/sce"
import "vito/vito"

when VITA {

	Asset_Type :: enum {
		IMAGE,
		AUDIO,
		MODEL,
	}

	/*
		Where print's lines are kept on the memory card. A real Vita shows nothing from
		sceClibPrintf without a plugin, so a run that crashes or hangs on hardware would leave
		no trace; this file is read afterwards with VitaShell or FTP. It is for those runs:
		anything meant to be seen while playing is drawn with render_text instead
	*/
	Print_Log :: struct {
		path:cstring, // one file for every game: ux0:data always exists, and a game's own folder would need its title id
		started:bool, // emptied for this run, by init or the first print
	}

	/*
		Prints a line to Vita3K's log window (a tty or log plugin on a real console) and to the
		print log file. Formats on the stack, 1024 bytes at most; longer lines are cut off
	*/
	print :: proc(args: ..any) {
		buffer:[1024]u8
		line := fmt.bprintln(buffer[:], ..args, sep = " ")
		vito.write(line) // one write: Vita3K logs each sceClibPrintf call as a line of its own

		start_print_log(&mbi.print_log)
		// Opened, written and closed for every line, the way vito's crash report does it. A file
		// kept open lost every line before a crash in Vita3K: the writes sat in a buffer that
		// was never flushed, and only the crash report, written and closed, survived. Slow, but
		// print is for tracing a crash or a hang, not for every frame
		file := sce.sceIoOpen(mbi.print_log.path, sce.O_WRONLY | sce.O_CREAT | sce.O_APPEND, 0o777)
		if file < 0 do return
		sce.sceIoWrite(file, raw_data(line), sce.Size(len(line)))
		sce.sceIoClose(file)
	}

	/*
		Deletes last run's file once per run, so it holds this run only; the first line makes it
		again. Removed rather than opened with O_TRUNC, which Vita3K ignores: the file grew by a
		run each time
	*/
	@(private)
	start_print_log :: proc(log:^Print_Log) {
		if log.started do return
		log.started = true
		sce.sceIoRemove(log.path)
	}

	/*
		Returns the app0: path for an asset. The build has already chosen shared vs Vita-only
		(assets\vita wins) and packed the files as they are, so `filename` means the same file
		here as on PC: no extension to change, unlike the 3DS's .t3x
	*/
	get_asset :: proc(buffer: []u8, filename: string, asset_type: Asset_Type) -> (path: cstring, ok: bool) {
		switch asset_type {
		case .IMAGE:
			return build_path(buffer, mbi.asset_path, "images/", filename)
		case .AUDIO:
			return build_path(buffer, mbi.asset_path, "audio/", filename)
		case .MODEL:
			// The build turned models/<name>.gltf or .glb into models/<name>.mbm (tools/modelpack.odin)
			return build_path(buffer, mbi.asset_path, "models/", strip_extension(filename), ".mbm")
		}
		return nil, false
	}

	/*Reads a whole file into memory the caller deletes. nil when the file cannot be read. The 3DS's has the same name and shape*/
	read_file_bytes :: proc(path:cstring) -> []u8 {
		bytes, ok := vito.read_entire_file(path)
		if ok == false do return nil
		return bytes
	}
}
