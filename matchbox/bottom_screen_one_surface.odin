package matchbox

/*
	Bottom screen on one surface
	============================
	Draw the 3DS bottom screen's content between bottom_screen_start and bottom_screen_end:

		mb.bottom_screen_start()
		mb.render_sprite(button)   // placed with mb.bottom_screen_anchor_position
		mb.bottom_screen_end()

	What happens to it depends on the layout, set with set_bottom_screen:

		.HIDDEN      (the default) the drawing is queued and thrown away; nothing reaches the window
		.FULLSCREEN  the bottom screen fills the window. The game draws only this and skips the world

	A game that wants to skip the work of drawing a hidden screen asks is_bottom_screen_visible.
	It is a screen camera, like the HUD, and the same rules apply: between render_start and
	render_end, not nested with another camera.

	For every target with one surface: the PC and the Vita, which behave the same here. The
	3DS has a real second screen and its own file (bottom_screen_3ds_freestanding_arm32.odin),
	so this one is inside `when`, which is the only way to say "not the 3DS" -- both handhelds
	are freestanding_arm32, so no file suffix or build tag can tell them apart (target.odin)
*/

when ODIN_OS != .Freestanding || VITA {

	/*Picks what bottom_screen_start / bottom_screen_end do from now on*/
	set_bottom_screen :: proc(layout:Bottom_Screen_Layout) {
		mbi.bottom_screen_layout = layout
	}

	get_bottom_screen_layout :: proc() -> Bottom_Screen_Layout {
		return mbi.bottom_screen_layout
	}

	/*False when the bottom screen is hidden, so a game can skip drawing it entirely*/
	is_bottom_screen_visible :: proc() -> bool {
		return mbi.bottom_screen_layout != .HIDDEN
	}

	// The bottom screen's camera: the same units as the HUD, grown taller in a window narrower than 4:3
	@(private)
	get_bottom_screen_camera :: proc() -> Camera {
		return create_screen_camera(calculate_bottom_screen_view_height(mbi.screen_height, calculate_window_aspect()))
	}

	/*Everything drawn until bottom_screen_end is the bottom screen: shown when FULLSCREEN, thrown away when HIDDEN*/
	bottom_screen_start :: proc() {
		camera_start(get_bottom_screen_camera())
		mbi.discard_pass = is_bottom_screen_visible() == false
	}

	bottom_screen_end :: proc() {
		camera_end()
	}

	/*The corners of the bottom screen's view, in its units: `min` bottom left, `max` top right*/
	calculate_bottom_screen_visible_rectangle :: proc() -> (min, max:[2]f32) {
		return calculate_camera_visible_rectangle(get_bottom_screen_camera(), calculate_window_aspect())
	}

	/*A bottom screen position pinned to `anchor` and moved by `offset`. See calculate_camera_anchor_position*/
	calculate_bottom_screen_anchor_position :: proc(anchor:Anchor, offset:[2]f32 = {}) -> [3]f32 {
		return calculate_camera_anchor_position(get_bottom_screen_camera(), calculate_window_aspect(), anchor, offset)
	}

	/*
		The mouse in the bottom screen's units, as touch would be on a 3DS, and whether it is
		on the screen at all. `inside` is false while the screen is hidden, so a hidden button
		cannot be clicked, and false when the mouse is outside the window.
		Use it with is_point_in_rectangle:

			position, inside := mb.calculate_mouse_bottom_screen_position()
			if inside && mb.is_point_in_rectangle(position, button_min, button_max) && mb.is_mouse_pressed(.LEFT) { ... }
	*/
	calculate_mouse_bottom_screen_position :: proc() -> (position:[2]f32, inside:bool) {
		if is_bottom_screen_visible() == false do return {}, false

		position = calculate_mouse_world_position(get_bottom_screen_camera())
		min, max := calculate_bottom_screen_visible_rectangle()
		inside = is_point_in_rectangle(position, min, max)
		return
	}
}
