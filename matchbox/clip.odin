package matchbox

/*
	Clipping the screen pass (the HUD) to a rectangle
	=================================================
	The types, shared by every target so a Render_Item can carry its clip. The procedures are the PC's
	(clip_windows.odin); the 3DS and the Vita do not clip, and their `clip_start` does nothing (clip_handheld_freestanding_arm32.odin)

		mb.screen_start()
		mb.clip_start({-4, -3}, {4, 3})      // the list's area, in HUD units: min bottom left, max top right
		for row in rows { ... render_text ... }
		mb.clip_end()
		mb.screen_end()

	A clip is in the units of the pass it is made in (the HUD's), measured like everything else there: +Y up, the origin at
	the middle. It is turned into pixels when it is made, and each draw queued while it is active carries the pixels, because
	the draws are made at screen_end, long after clip_end
*/

// How many clips can be open inside each other: a fixed array bound, so a constant
MAX_CLIP_DEPTH :: 16

// A clip in window (or render target) pixels, top left origin, `right` and `bottom` one past the last pixel: a D3D scissor rectangle
Clip_Rectangle :: struct {
	left:   i32,
	top:    i32,
	right:  i32,
	bottom: i32,
}

// What clip_start keeps. Lives in `mbi.clip`
Clip_State :: struct {
	// The pass being drawn: set by camera_start for a screen camera, so a clip can be turned into pixels
	units_to_pixels: f32, // pixels in one unit
	centre_units:    [2]f32, // the unit at the middle of the target
	target_pixels:   [2]i32, // the size of the target it draws to

	// The open clips in HUD units, each already cut down to the one below it
	stack_min:       [MAX_CLIP_DEPTH][2]f32,
	stack_max:       [MAX_CLIP_DEPTH][2]f32,
	depth:           int,

	// What a draw queued now carries: the pixels of the innermost clip. `active` is false when there is none
	current:         Clip_Rectangle,
	active:          bool,
}
