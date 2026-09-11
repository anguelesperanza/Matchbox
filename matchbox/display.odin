package matchbox

/*
	Display
	-------
	The window and everything about mapping logical (game) coordinates onto it.

	Matchbox draws in a *logical* resolution (`width` x `height`). When
	`fixed_res` is on, that logical image is scaled up to fit the real window
	and centered, which is what `draw_scale` and `draw_offset` describe. Every
	draw call runs its coordinates through screen_pos/screen_size so games can
	work in logical space and ignore the actual window size.
*/

import "core:log"

import sdl "vendor:sdl3"

Display :: struct {
	window:        ^sdl.Window,
	title:         string,
	flags:         sdl.WindowFlags,
	screen_type:   Screen_Type, // WINDOWED until set_screen_type says otherwise
	window_width:  i32,      // real window size, in pixels -- not points, see begin_drawing
	window_height: i32,

	// Window pixels per window point. 1 on an unscaled display, 1.25 or 1.5 or 2
	// on a scaled one. The window is created with .HIGH_PIXEL_DENSITY, so its
	// pixel size is its point size times this -- and SDL reports mouse positions
	// in points, which is the one place the two have to be reconciled.
	pixel_density: f32,
	width:         i32,      // logical render size, what games draw against
	height:        i32,
	fixed_res:     bool,     // true = letterbox the logical size into the window
	draw_scale:    f32,      // logical -> window multiplier
	draw_offset:   [2]f32,   // letterbox margin, in window pixels

	// How much bigger than one window pixel a logical pixel is drawn when no
	// logical size is pinned. See set_ui_scale; zero reads as 1.
	ui_scale:      f32,
}

// -----------------------------------------------------------------------
// Screen type
// -----------------------------------------------------------------------

/*
	The three ways a window can occupy the screen.

	WINDOWED is bordered and resizable -- what every Matchbox window starts
	in. FULLSCREEN takes the display over at its own current mode (what SDL
	calls "exclusive" fullscreen, and the reason that word still means
	something even though SDL3 folded the old separate fullscreen-desktop
	flag away -- see set_screen_type). WINDOWED_FULLSCREEN draws the same
	picture, a borderless window the size of the whole screen, without
	taking the display over -- alt-tabbing away from it does not have to
	change video mode back and forth the way leaving FULLSCREEN does.
*/
Screen_Type :: enum {
	WINDOWED,
	FULLSCREEN,
	WINDOWED_FULLSCREEN,
}

/*
	vendor:sdl3's own SetWindowFullscreenMode takes its mode `#by_ptr`, which
	Odin can only fill from an addressable DisplayMode value -- there is no
	way to pass it nil through that binding. NULL is exactly what
	SDL_video.h documents SetWindowFullscreenMode as wanting for "borderless
	fullscreen desktop mode", and it is the one call set_screen_type needs to
	get back from FULLSCREEN's exclusive mode to WINDOWED_FULLSCREEN's.

	A second `foreign import` of the same library, declaring the same C
	symbol with a real nilable pointer, is the obvious fix and does not work:
	Odin tracks foreign symbols across the whole program by their linked
	name, and rejects two declarations of "SDL_SetWindowFullscreenMode" that
	disagree on their Odin type even though they live in different packages.
	Transmuting the *already-declared* proc value sidesteps that -- both
	sides are "c"-convention procedures, which are bare code pointers with no
	Odin-side representation of their own, so reinterpreting one as a
	different but ABI-compatible signature is exactly what transmute is for,
	and it is one already-linked symbol rather than a second declaration of
	it.
*/
set_window_fullscreen_mode :: proc(window: ^sdl.Window, mode: ^sdl.DisplayMode) -> bool {
	nilable := transmute(proc "c" (window: ^sdl.Window, mode: ^sdl.DisplayMode) -> bool)sdl.SetWindowFullscreenMode
	return nilable(window, mode)
}

/*
	Changes how the window occupies the screen -- see Screen_Type for what
	each value means. A no-op if the window is already there, so a game can
	drive this from a settings menu every frame without SDL re-issuing the
	same window-manager request each time.

	Logs and leaves the screen type unchanged if the window manager refuses
	the request -- SDL_video.h notes fullscreen changes are only a request on
	some platforms -- rather than recording a state the window is not
	actually in.
*/
set_screen_type :: proc(type: Screen_Type) {
	if mbi.window == nil || mbi.screen_type == type do return

	switch type {
	case .WINDOWED:
		if !sdl.SetWindowFullscreen(mbi.window, false) {
			log.errorf("could not leave fullscreen: %s", sdl.GetError())
			return
		}

	case .WINDOWED_FULLSCREEN:
		if !set_window_fullscreen_mode(mbi.window, nil) {
			log.errorf("could not clear the exclusive fullscreen mode: %s", sdl.GetError())
			return
		}
		if !sdl.SetWindowFullscreen(mbi.window, true) {
			log.errorf("could not enter fullscreen: %s", sdl.GetError())
			return
		}

	case .FULLSCREEN:
		// The display's own current mode, not a lower resolution to render
		// at -- Matchbox has no resolution picker, and reusing the desktop's
		// own mode is what keeps this from visibly changing anything but
		// exclusivity. A mode that cannot be read degrades to borderless
		// (whatever exclusive mode -- if any -- the window already had),
		// logged rather than silently passed since it is not the state asked
		// for, unlike this package's other degrades.
		display := sdl.GetDisplayForWindow(mbi.window)
		mode := sdl.GetDesktopDisplayMode(display)
		if mode == nil || !set_window_fullscreen_mode(mbi.window, mode) {
			log.errorf("could not set an exclusive fullscreen mode, falling back to borderless: %s", sdl.GetError())
		}
		if !sdl.SetWindowFullscreen(mbi.window, true) {
			log.errorf("could not enter fullscreen: %s", sdl.GetError())
			return
		}
	}

	mbi.screen_type = type
}

// What set_screen_type last actually managed to put the window into --
// WINDOWED until a game calls it.
get_screen_type :: proc() -> Screen_Type {
	return mbi.screen_type
}

// Steps to the next Screen_Type in the order the type declares them --
// WINDOWED -> FULLSCREEN -> WINDOWED_FULLSCREEN -> WINDOWED -- the shape a
// single key (F11, say) wants without a game tracking the state itself.
toggle_screen_type :: proc() {
	set_screen_type(Screen_Type((int(mbi.screen_type) + 1) % len(Screen_Type)))
}

// -----------------------------------------------------------------------
// Logical resolution / screen helpers
// -----------------------------------------------------------------------

// Pins the resolution games draw against. From here on the logical image is
// scaled to fit the window and centered, so a resize letterboxes rather than
// changing how much of the world is on screen.
//
// Off by default -- without this, width/height follow the window size.
set_logical_size :: proc(width: i32, height: i32) {
    mbi.width     = width
    mbi.height    = height
    mbi.fixed_res = true
}

/*
	Draws everything bigger without letterboxing it: the logical size becomes
	the window's pixels divided by `scale`, and every 2D draw, hit test and
	pointer position follows. At 2 a 1600x900 window lays out as 800x450 and
	each logical pixel covers four window pixels.

	What an accessibility setting wants, or anything read from across a room.
	The window is made at the display's full pixel density, so on a display the
	operating system scales -- a 4K TV at 200 percent, a laptop at 150 --
	a scale of 1 draws everything at a fraction of the size other programs
	there use. `get_display_scale` is the scale they use.

	Text in the default face is drawn from a face baked at the scaled size, so
	it stays sharp rather than stretched; see `draw_glyphs`. A size set by
	`set_logical_size` takes precedence, since it already says how big things
	are. Zero or less is taken as 1.
*/
set_ui_scale :: proc(scale: f32) {
	mbi.ui_scale = scale if scale > 0 else 1
}

// The UI scale set by set_ui_scale, 1 until one is.
get_ui_scale :: proc() -> f32 {
	return mbi.ui_scale if mbi.ui_scale > 0 else 1
}

/*
	The scale the operating system draws other programs at on the window's
	display: 1.5 for Windows set to 150 percent, 2 on a Retina Mac. SDL's own
	`GetWindowDisplayScale`, which counts pixel density and the user's scaling
	setting together -- the multiplier from a design in pixels to the window's
	pixels, which is what `set_ui_scale` takes. 1 before `init` or when the
	display will not say.
*/
get_display_scale :: proc() -> f32 {
	if mbi.window == nil do return 1
	scale := sdl.GetWindowDisplayScale(mbi.window)
	return scale if scale > 0 else 1
}

/*
	This frame's logical size and logical-to-window transform, from the window's
	size in pixels. `begin_drawing` calls it; it is apart from it so that it is
	tested without a window.

	- A pinned size (`set_logical_size`) is scaled to fit and centred, with
	  the margin left over as a letterbox. The UI scale does not apply.
	- Otherwise the logical size is the window divided by the UI scale, from
	  the top-left, with no margin -- at a scale of 1, the window itself, as it
	  always was. A window a pixel or two wider than a whole number of logical
	  pixels leaves them uncovered at the right and bottom, under the clear.
*/
@(private)
update_display_transform :: proc() {
	if mbi.fixed_res {
		scale_x := f32(mbi.window_width)  / f32(mbi.width)
		scale_y := f32(mbi.window_height) / f32(mbi.height)
		mbi.draw_scale = min(scale_x, scale_y)
		scaled_w := f32(mbi.width)  * mbi.draw_scale
		scaled_h := f32(mbi.height) * mbi.draw_scale
		mbi.draw_offset = {
			(f32(mbi.window_width)  - scaled_w) * 0.5,
			(f32(mbi.window_height) - scaled_h) * 0.5,
		}
		return
	}

	scale := get_ui_scale()
	mbi.width       = i32(f32(mbi.window_width)  / scale)
	mbi.height      = i32(f32(mbi.window_height) / scale)
	mbi.draw_scale  = scale
	mbi.draw_offset = {0, 0}
}

// A world position as the shader wants it, with the camera and the letterbox
// applied. What every 2D draw runs its position through.
screen_pos :: proc(pos: [2]f32) -> [2]f32 {
	if mbi.camera.active {
		screen_center := [2]f32{cast(f32)mbi.width * 0.5, cast(f32)mbi.height * 0.5}
		zoom: f32 = 1
		if mbi.camera.zoom > 0 {
			zoom = mbi.camera.zoom
		}
		logical := (pos - mbi.camera.position) * zoom + screen_center
		return logical * mbi.draw_scale + mbi.draw_offset
	}
	return pos * mbi.draw_scale + mbi.draw_offset
}

// The camera zoom has to be applied here as well as in screen_pos. Every draw
// call pairs the two, so scaling only the position pulled things closer
// together while leaving them full size -- zoom out far enough and neighbours
// that are laid out apart start to overlap.
screen_size :: proc(size: [2]f32) -> [2]f32 {
	if mbi.camera.active {
		zoom: f32 = 1
		if mbi.camera.zoom > 0 {
			zoom = mbi.camera.zoom
		}
		return size * zoom * mbi.draw_scale
	}
	return size * mbi.draw_scale
}

// The size everything 2D is measured against this frame.
get_screen_dims :: proc() -> [2]f32 {
	// The render target when one is bound, so that 2D drawn into a texture of
	// a different size than the window lands inside it rather than off the
	// edge. The window otherwise, which is every frame that has no target.
	return get_current_target_size()
}
