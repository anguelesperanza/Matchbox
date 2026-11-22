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
}
