package demo

import mb "matchbox"

/*
	The handhelds' entry point, the same file for the 3DS and the Vita. main.c calls odin_main,
	and this sets up Odin's runtime before the game's `main` runs. It lives in the game's
	package, not in Matchbox, because `context` is the caller's: Matchbox can return one
	(start_runtime) but cannot set it for the game
*/
@(export, link_name = "odin_main")
odin_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
	context = mb.start_runtime()
	main()
	mb.stop_runtime()
	return 0
}
