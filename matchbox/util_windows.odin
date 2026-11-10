#+build windows

package matchbox

/*
	Util
	====
	This file contains utility procedures +
	procedures I couldn't thematically find a spot for
*/

import "core:fmt"
import "core:strings"
import "core:os"

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
	fmt.println(..args)
}

/*
	returns the size of the window for a given target
	return value is a [4]i32 as the 3DS backend has two screens
	On PC & Vita: value[0] and value[1] are all you need
	On 3DS:
		value[0] => top screen width
		value[1] => top screen height
		value[2] => bottom screen width
		value[3] => bottom screen height
*/

get_window_size :: proc() -> [4]i32 {
	return mbi.window_size
}


/*
	Find the correct asset path and returns it
	Checks shared assets first, then checks target specific

	The last one found is the one returned
*/


/*
	Find the correct asset path and returns it
	Checks target specific assets first, then shared assets

	The caller owns the returned string and should delete it
*/
get_asset :: proc(filename:string, asset_type:Asset_Type) -> string {

	folder := "images/"
	if asset_type == .AUDIO do folder = "audio/"

	// Target-specific first
	dir := strings.concatenate({mbi.target_asset_path, folder})
	file := strings.concatenate({dir, filename})
	delete(dir)
	if os.is_file(file) do return file
	delete(file)

	// Then shared
	dir = strings.concatenate({mbi.asset_path, folder})
	file = strings.concatenate({dir, filename})
	delete(dir)
	if os.is_file(file) do return file
	delete(file)

	print("Asset not found")
	panic("Asset not found")
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
