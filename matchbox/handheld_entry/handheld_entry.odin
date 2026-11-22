#+build freestanding arm32

package matchbox_handheld_entry

/*
	Handheld entry point
	====================
	The handhelds' entry point, the same for the 3DS and the Vita. main.c calls odin_main, and
	this sets up Odin's runtime before the game's `main` runs.

	It is its own package, and what 3ds_build.bat and vita_build.bat build: the game is imported
	through the `matchbox_game` collection, which the scripts point at the game's folder. The
	alternative, a file in the game's package, had to name that package, so a copy of it in a
	game called anything but `demo` failed to compile. Here the game's package can be called
	anything, and a game carries no entry file at all.

	Matchbox itself still can't hold this: `context` is set here and passed on to the game's
	`main`, and Matchbox's own procedures can only return one (start_runtime), not set it for
	their caller
*/

import game "matchbox_game:."

import mb ".."

@(export, link_name = "odin_main")
odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
	context = mb.start_runtime()
	game.main()
	mb.stop_runtime()
	return 0
}
