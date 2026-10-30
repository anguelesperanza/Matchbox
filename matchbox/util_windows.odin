#+build windows

package matchbox

/*
	Util
	====
	This file contains utility procedures +
	procedures I couldn't thematically find a spot for
*/

import "core:fmt"

/*
	prints a line to the console
		- Needed as fmt does not work on freestanding
	On windows, called fmt.println()
*/
print :: proc(args: ..any) {
	fmt.println(..args)
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
