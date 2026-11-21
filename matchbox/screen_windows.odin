#+build windows

package matchbox

/*
	Screen space
	============
	A HUD is drawn after the world, through a screen camera: depth off, in the units of
	`set_screen_height`, pinned to the corners of the window with anchors.

		mb.camera_start(camera)
		mb.render_sprite(player)
		mb.camera_end()

		mb.screen_start()
		mb.render_sprite(health_bar)   // placed with mb.anchor_position
		mb.screen_end()

	`screen_start` is `camera_start` with the screen camera, so it follows the same rules:
	between render_start and render_end, not nested.
*/

/*How many world units tall the HUD is. 12 units at 16 pixels per unit is 192 pixels, say.
Everything in the screen pass is measured in these units, whatever the window size is*/
set_screen_height :: proc(units:f32) {
	ensure(units > 0, "set_screen_height needs a height above 0")
	mbi.screen_height = units
}

// The HUD camera: always at the origin, as tall as set_screen_height says
@(private)
get_screen_camera :: proc() -> Camera {
	return create_screen_camera(mbi.screen_height)
}

/*Window width over height, 1 when the window has no height yet (it is minimised)*/
@(private)
calculate_window_aspect :: proc() -> f32 {
	if mbi.window_size[1] <= 0 do return 1
	return f32(mbi.window_size[0]) / f32(mbi.window_size[1])
}

/*Everything drawn until screen_end is HUD: depth off, in the units of set_screen_height*/
screen_start :: proc() {
	camera_start(get_screen_camera())
}

screen_end :: proc() {
	camera_end()
}

/*The corners of the HUD view, in HUD units: `min` bottom left, `max` top right.
It widens and narrows as the window does; the height stays set_screen_height*/
calculate_visible_rectangle :: proc() -> (min, max:[2]f32) {
	return calculate_camera_visible_rectangle(get_screen_camera(), calculate_window_aspect())
}

/*A HUD position pinned to `anchor` and moved by `offset`. See calculate_camera_anchor_position*/
calculate_anchor_position :: proc(anchor:Anchor, offset:[2]f32 = {}) -> [3]f32 {
	return calculate_camera_anchor_position(get_screen_camera(), calculate_window_aspect(), anchor, offset)
}

/*Where the mouse is on the HUD, in HUD units (+Y up, the same space as calculate_anchor_position).
Use it to click things drawn between screen_start and screen_end*/
calculate_mouse_screen_position :: proc() -> [2]f32 {
	return calculate_mouse_world_position(get_screen_camera())
}
