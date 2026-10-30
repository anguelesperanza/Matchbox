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
