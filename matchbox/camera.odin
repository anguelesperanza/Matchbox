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
	in_use:   bool,   // true once begin_drawing_2d has been called at least once
	follow_speed:f32, // How fast the camera will follow the position (used for lerp)
}

// Activates the camera transform for all subsequent draw calls.
// Draw world-space sprites (players, enemies, tiles) between this and end_drawing_2d.
begin_drawing_2d :: proc() {
    mbi.camera.active = true
    mbi.camera.in_use = true
}

// Deactivates the camera transform.
// Draw screen-space elements (UI, HUD, text) after this call.
end_drawing_2d :: proc() {
    mbi.camera.active = false
}

// Returns the mouse position in world space, accounting for camera position and zoom.
// Use this instead of get_mouse_position when clicking on world objects;
// get_mouse_position gives logical screen-space coordinates for UI.
//
// This is the inverse of the camera branch of screen_pos. It keys off `in_use`
// rather than `active` so that it works in update code, which is where you
// normally ask where the mouse is pointing -- `active` is only set between
// begin_drawing_2d and end_drawing_2d, so gating on it meant this quietly
// returned a screen position everywhere it was actually useful.
//
// A game that never draws through a camera gets get_mouse_position back, which
// is the same thing in that case.
get_mouse_world_pos :: proc() -> [2]f32 {
	if !mbi.camera.in_use {
		return get_mouse_position()
	}
	screen_center := [2]f32{cast(f32)mbi.width * 0.5, cast(f32)mbi.height * 0.5}
	zoom: f32 = 1
	if mbi.camera.zoom > 0 {
		zoom = mbi.camera.zoom
	}
	return (get_mouse_position() - screen_center) / zoom + mbi.camera.position
}
