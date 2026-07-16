package matchbox

// -----------------------------------------------------------------------
// Logical resolution / screen helpers
// -----------------------------------------------------------------------

set_logical_size :: proc(mbi: ^MatchboxInfo, width: i32, height: i32) {
    mbi.width     = width
    mbi.height    = height
    mbi.fixed_res = true
}

screen_pos :: proc(mbi: ^MatchboxInfo, pos: [2]f32) -> [2]f32 {
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

screen_size :: proc(mbi: ^MatchboxInfo, size: [2]f32) -> [2]f32 {
	return size * mbi.draw_scale
}

screen_dims :: proc(mbi: ^MatchboxInfo) -> [2]f32 {
	return {cast(f32)mbi.window_width, cast(f32)mbi.window_height}
}

// -----------------------------------------------------------------------
// Camera
// -----------------------------------------------------------------------

// Activates the camera transform for all subsequent draw calls.
// Draw world-space sprites (players, enemies, tiles) between this and end_drawing_2d.
begin_render_2d :: proc(camera: ^Camera) {
    camera.active = true
}

// Deactivates the camera transform.
// Draw screen-space elements (UI, HUD, text) after this call.
end_render_2d :: proc(camera: ^Camera) {
    camera.active = false
}

// Returns the mouse position in world space, accounting for camera position and zoom.
// Use this instead of mbi.mouse when clicking on world objects.
// mbi.mouse gives logical screen-space coordinates for UI.
get_mouse_world_pos :: proc(mbi: ^MatchboxInfo) -> [2]f32 {
	if !mbi.camera.active {
		return {mbi.input.mouse_dx, mbi.input.mouse_dy}
	}
	screen_center := [2]f32{cast(f32)mbi.width * 0.5, cast(f32)mbi.height * 0.5}
	zoom: f32 = 1
	if mbi.camera.zoom > 0 {
		zoom = mbi.camera.zoom
	}
	return ({mbi.input.mouse_dx, mbi.input.mouse_dy} - screen_center) / zoom + mbi.camera.position
}
