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
	MODEL,
	SHADER,
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
	Checks target specific assets first, then shared assets

	The caller owns the returned string and should delete it
*/
get_asset :: proc(filename:string, asset_type:Asset_Type) -> string {
	path, found := find_asset(filename, asset_type)
	if found == false {
		print("Asset not found")
		panic("Asset not found")
	}
	return path
}

// The folder under assets/ that holds a kind of asset, with its trailing slash
@(private)
get_asset_folder_name :: proc(asset_type:Asset_Type) -> string {
	switch asset_type {
	case .AUDIO: return "audio/"
	case .MODEL: return "models/"
	case .SHADER: return "shaders/"
	case .IMAGE: return "images/"
	}
	return "images/"
}

/*The same lookup as get_asset, but a file that is not there is `found` = false and not a stop*/
find_asset :: proc(filename:string, asset_type:Asset_Type) -> (path:string, found:bool) {

	folder := get_asset_folder_name(asset_type)

	// Target-specific first
	dir := strings.concatenate({mbi.target_asset_path, folder})
	file := strings.concatenate({dir, filename})
	delete(dir)
	if os.is_file(file) do return file, true
	delete(file)

	// Then shared
	dir = strings.concatenate({mbi.asset_path, folder})
	file = strings.concatenate({dir, filename})
	delete(dir)
	if os.is_file(file) do return file, true
	delete(file)
	return "", false
}
