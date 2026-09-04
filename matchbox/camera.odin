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

/*
	Eases the camera toward `target`, once per frame.

	A camera pinned exactly to the player is what makes a 2D game feel stiff:
	every step the player takes, the whole world steps with it. Letting the
	camera lag and catch up is what `follow_speed` was always for, and until now
	nothing read it.

		mb.camera_follow(sprite_center(player), mb.get_delta_time())

	**A `follow_speed` of 0 means the camera does not follow at all.** That is
	the zero value, so a camera nobody has configured stays where it was put
	rather than snapping to whatever is passed here -- set `follow_speed` before
	the first call. A negative one is read the same way, since a camera easing
	*away* from its target is not a thing anybody wants by accident.

	**Why the factor is clamped.** The obvious form is
	`position += (target - position) * speed * dt`, and that is what this is --
	but `speed * dt` passes 1 on a stalled frame or with a high `follow_speed`,
	and past 1 the camera overshoots the target and oscillates around it, worse
	the larger the product gets. Clamping turns the worst case into a snap,
	which reads as a cut rather than a wobble.

	The exactly frame-rate-independent form is `1 - exp(-speed * dt)`: it can
	never overshoot, and it gives the same easing whatever the frame time. It is
	not what is here because the linear form is the one this API was designed
	around and the one written on the tin. The two diverge by roughly
	`speed * dt / 2` per step -- a slightly different curve at ordinary frame
	times, and nothing a player can see. Swap it in if the frame time ever
	varies enough to matter.
*/
camera_follow :: proc(target: [2]f32, delta_time: f32) {
	t := mbi.camera.follow_speed * delta_time
	if t <= 0 do return

	mbi.camera.position += (target - mbi.camera.position) * min(t, 1)
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
