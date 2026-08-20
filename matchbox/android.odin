package matchbox

/*
	The only Android-specific code in matchbox: an entry point, and a stub that
	exists in order never to be called.

	Android does not start a native program. SDL's Java activity does, by
	dlopen-ing libmain.so and calling a symbol named `SDL_main` in it, so
	something has to answer to that name.

	The obvious candidate is wrong, and quietly so. Odin emits a `main` for every
	non-Windows target, but in `-build-mode:shared` that `main` is a stub that
	returns 0 -- nothing else. Aliasing SDL_main to it produces a program that
	installs, launches, runs for one millisecond, and exits without a word:

		V SDL: Running main function SDL_main from library .../libmain.so
		V SDL: Finished main function

	What actually starts an Odin shared library is `_odin_entry_point`, which
	Odin generates for `ODIN_BUILD_MODE == .Dynamic` (see base/runtime's
	entry_unix.odin). It sets up the context, runs `__$startup_runtime` -- global
	initialisers, @(init) procedures -- and then calls the program's `main`.
	Teardown is `_odin_exit_point`, already registered in .fini_array, so it is
	not called here.

	So SDL_main is a real procedure with the signature SDL expects, and it defers
	to the one Odin already wrote. Nothing an example does has to change.
*/

when ODIN_PLATFORM_SUBTARGET == .Android {

	foreign {
		@(link_name="_odin_entry_point")
		odin_entry_point :: proc "c" () ---
	}

	@(export)
	SDL_main :: proc "c" (argc: i32, argv: [^]cstring) -> i32 {
		odin_entry_point()
		return 0
	}

	/*
		`-subtarget:android` always compiles android_native_app_glue.c in and
		forces ANativeActivity_onCreate, because it assumes a NativeActivity
		program. This is not one, so the glue never runs -- but it still has to
		link, and it references `android_main`. Android resolves every symbol
		when a library is loaded rather than on first call, so leaving it
		undefined is not a link warning, it is

			dlopen failed: cannot locate symbol "android_main"

		in a dialog at launch.
	*/
	@(export)
	android_main :: proc "c" (app: rawptr) {
		// Deliberately empty. See above.
	}
}
