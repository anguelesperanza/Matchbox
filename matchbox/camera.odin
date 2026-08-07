package matchbox

/*
	Camera
	------
	A 2D camera. While active, screen_pos (see display.odin) offsets every draw
	by the camera position and zoom, so world-space coordinates land in the
	right place on screen.
*/

Camera :: struct {
	position: [2]f32, // world point the camera is centered on
	zoom:     f32,    // 1.0 = normal, >1 zooms in, <1 zooms out
	active:   bool,   // true while inside begin_drawing_2d / end_drawing_2d
	follow_speed:f32, // How fast the camera will follow the position (used for lerp)
}

// Activates the camera transform for all subsequent draw calls.
// Draw world-space sprites (players, enemies, tiles) between this and end_drawing_2d.
begin_drawing_2d :: proc(camera: ^Camera) {
    camera.active = true
}

// Deactivates the camera transform.
// Draw screen-space elements (UI, HUD, text) after this call.
end_drawing_2d :: proc(camera: ^Camera) {
    camera.active = false
}

// Returns the mouse position in world space, accounting for camera position and zoom.
// Use this instead of mbi.input.mouse when clicking on world objects.
// mbi.input.mouse gives logical screen-space coordinates for UI.
get_mouse_world_pos :: proc() -> [2]f32 {
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
