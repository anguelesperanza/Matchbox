#+build freestanding arm32

package matchbox

/*
	Backend (3DS)
	=============
	What only the 3DS has: citro3d's render targets, the circle pad and C-stick, the HID
	button masks. Embedded in Matchbox_Info with `using`, like the PC's. See
	matchbox_info.odin for the contract this file fills in.

	Everything is inside `when !VITA` because the Vita is freestanding_arm32 too, so this
	file's suffix alone would compile it into the Vita build as well (target.odin). The
	imports stay outside: Odin does not allow `import` inside `when`, and an import whose
	procedures are never called adds nothing to the build.

	Textures and meshes are empty until Phase C draws: the contract only needs the names
	to exist so the shared files compile.
*/

import "base:runtime"

import "o3dx/o3dx"

when !VITA {

	Backend_State :: struct {
		// citro3d render targets, as `rawptr` because that is how o3dx's c3d binds them
		top_screen:rawptr,
		bottom_screen:rawptr,

		// HID button masks for this frame (hidKeysDown / Held / Up)
		gamepad_pressed:u32,
		gamepad_held:u32,
		gamepad_released:u32,

		// The circle pad and C-stick, scaled to -1..1 by the largest value each reaches
		left_thumbstick_axis:[2]f32,
		right_thumbstick_axis:[2]f32,
		left_thumbstick_max:f32,
		right_thumbstick_max:f32,

		timestamp:Timestamp, // osGetTime values, so its type is the 3DS's own

		// Fixed values the 3DS backend works with
		display_settings:Display_Settings,
	}

	/*
		The 3DS's half of `mbi`'s initial values. Same reason as the PC's BACKEND_DEFAULTS:
		a global's initial value must be known at compile time
	*/
	BACKEND_DEFAULTS :: Backend_State {
		display_settings = {transfer_flags = 0x1000},

		// The largest values the New 3DS LL used for testing reports. Not a setting: they
		// scale what the hardware gives, so they are right from the start
		left_thumbstick_max = 156,
		right_thumbstick_max = 146,
	}

	/*Empty until Phase C uploads textures with citro3d*/
	Backend_Texture :: struct {}

	/*Empty until Phase C builds vertex buffers with citro3d*/
	Mesh :: struct {}

	/*
		Sets up the Odin runtime on the 3DS and returns the context the game runs in. Called
		from the game's entry_freestanding_arm32.odin, before `main`: Matchbox can't run it
		itself, because `context` belongs to the caller and nothing calls Odin before odin_main
	*/
	start_runtime :: proc "contextless" () -> runtime.Context {
		return o3dx.init()
	}

	/*Undoes start_runtime. Called after `main` returns*/
	stop_runtime :: proc "contextless" () {
		o3dx.shutdown()
	}

	/*
		Not loaded yet: returns a Texture of the right size once Phase C uploads it. Until then
		an empty Texture, so a game that loads images still runs and draws nothing
	*/
	load_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		texture.filter = filter
		return
	}

	/*
		A texture from RGBA8 pixels already in memory: what create_font uploads its atlas with.
		Records the size and uploads nothing until Phase C, so the sizes a game reads are right
	*/
	create_texture_from_pixels :: proc(pixels:rawptr, width, height:i32, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		texture.width = width
		texture.height = height
		texture.filter = filter
		return
	}

	/*Nothing to free until load_texture uploads something*/
	destroy_texture :: proc(texture:Texture) {
	}

	/*
		{top width, top height, bottom width, bottom height} in pixels, as the screens are held:
		400 x 240 on top, 320 x 240 below. citro3d's targets are 240 x 400 because the panels are
		mounted on their side; that is the backend's business, and the camera wants the size the
		player sees
	*/
	get_window_size :: proc() -> [4]i32 {
		return mbi.window_size
	}

	/*The 3DS has no mouse. The touch screen gets its own procedures when input is ported*/
	calculate_mouse_world_position :: proc(camera:Camera) -> [2]f32 {
		return {}
	}
}
