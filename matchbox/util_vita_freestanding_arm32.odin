#+build freestanding arm32

package matchbox

/*
	Util -- Vita
	============
	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "vito/vito"

when VITA {

	Asset_Type :: enum {
		IMAGE,
		AUDIO,
	}

	/*
		Prints a line to Vita3K's log window (a tty or log plugin on a real console), through
		sceClibPrintf. Formats on the stack, 1024 bytes at most; longer lines are cut off
	*/
	print :: proc(args: ..any) {
		vito.println(..args)
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
		}
		return nil, false
	}
}
