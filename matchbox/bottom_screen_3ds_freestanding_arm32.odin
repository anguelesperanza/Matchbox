#+build freestanding arm32

package matchbox

/*
	Bottom screen on the 3DS
	========================
	The same procedures as on one surface (bottom_screen_one_surface.odin), but the 3DS has
	the screen itself, 320 x 240 under the top one, so it is always there:

		.HIDDEN / .FULLSCREEN  change nothing: the layout is how a one-surface target fakes
		                       this screen, and the 3DS does not need to
		is_bottom_screen_visible  always true

	Its camera is the HUD's height in units and the bottom screen's own 4:3 shape. Drawing
	goes nowhere yet: the bottom screen holds the text console mb.print writes to, and has no
	citro3d target of its own (bottom_screen_start says more). The queue is recorded and
	emptied the same way as the top screen's.

	Inside `when !VITA` for the reason in backend_3ds_freestanding_arm32.odin
*/

when !VITA {

	/*Kept so a game can ask for it back, but the 3DS shows the bottom screen whatever it is*/
	set_bottom_screen :: proc(layout:Bottom_Screen_Layout) {
		mbi.bottom_screen_layout = layout
	}

	get_bottom_screen_layout :: proc() -> Bottom_Screen_Layout {
		return mbi.bottom_screen_layout
	}

	/*Always true: the 3DS has the screen*/
	is_bottom_screen_visible :: proc() -> bool {
		return true
	}

	// The bottom screen's camera: the HUD's height, the bottom screen's width
	@(private)
	get_bottom_screen_camera :: proc() -> Camera {
		return create_screen_camera(calculate_bottom_screen_view_height(mbi.screen_height, mbi.screen_settings.bottom_screen_aspect))
	}

	/*
		Everything drawn until bottom_screen_end is the bottom screen. Queued and thrown away for
		now: the bottom screen is the text console mb.print writes to (consoleInit in init), and
		it has no render target yet. Drawing it through the top screen's target would put the
		bottom screen's content over the top screen's
	*/
	bottom_screen_start :: proc() {
		camera_start(get_bottom_screen_camera())
		mbi.discard_pass = true
	}

	bottom_screen_end :: proc() {
		camera_end()
	}

	/*The corners of the bottom screen's view, in its units: `min` bottom left, `max` top right*/
	calculate_bottom_screen_visible_rectangle :: proc() -> (min, max:[2]f32) {
		return calculate_camera_visible_rectangle(get_bottom_screen_camera(), mbi.screen_settings.bottom_screen_aspect)
	}

	/*A bottom screen position pinned to `anchor` and moved by `offset`. See calculate_camera_anchor_position*/
	calculate_bottom_screen_anchor_position :: proc(anchor:Anchor, offset:[2]f32 = {}) -> [3]f32 {
		return calculate_camera_anchor_position(get_bottom_screen_camera(), mbi.screen_settings.bottom_screen_aspect, anchor, offset)
	}

	/*
		Where the stylus is, in the bottom screen's units, and whether it is down. Never down
		yet: the touch screen is read once input is ported
	*/
	calculate_mouse_bottom_screen_position :: proc() -> (position:[2]f32, inside:bool) {
		return {}, false
	}
}
