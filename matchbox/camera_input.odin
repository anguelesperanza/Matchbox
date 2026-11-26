package matchbox

/*
	Camera input
	============
	What the camera rigs and the character controls read, the same on all three targets: the
	mouse or the touch screen drags the view, the right stick (the 3DS C-stick) turns it, L and R
	zoom it, and WASD or the left stick or the d-pad move. Keys do nothing on the handhelds.
*/

/*Where the pointer moved between the last two poll_events, so a drag can turn a camera*/
Mouse_Motion :: struct {
	delta:[2]f32, // pixels, y down like get_mouse_position; 0 on the frame a drag starts
	previous:[2]f32,
	tracking:bool, // the pointer was already tracked last frame, so there is a previous position to measure from
}

/*Called by each target's poll_events; `active` is false while a touch screen is not touched, so a new touch does not jump*/
@(private)
update_mouse_motion :: proc(motion:^Mouse_Motion, position:[2]f32, active:bool) {
	motion.delta = position - motion.previous if active && motion.tracking else {}
	motion.previous = position
	motion.tracking = active
}

/*Pixels the pointer moved since the last poll_events (y down); on the handhelds, the touch drag*/
get_mouse_delta :: proc() -> [2]f32 {
	return mbi.mouse_motion.delta
}

/*How much a camera turns this frame, in radians (x left-positive, y up-positive), from a drag and the right stick*/
get_camera_look_input :: proc(sensitivity:f32, stick_speed:f32, delta_time:f32) -> [2]f32 {
	look:[2]f32

	// A drag only turns the view while a button is down, so moving the cursor to a menu does not
	if is_mouse_held(.LEFT) || is_mouse_held(.RIGHT) {
		drag := get_mouse_delta()
		look += {-drag.x, -drag.y} * sensitivity // dragging right turns right, which is a smaller yaw
	}

	stick := get_thumbstick_value(.RIGHT_THUMBSTICK)
	look += {-stick.x, stick.y} * stick_speed * delta_time
	return look
}

/*How far a camera zooms out this frame, in units per second of `speed`: R out, L in, and the wheel on PC*/
get_camera_zoom_input :: proc(speed:f32, delta_time:f32) -> f32 {
	zoom:f32
	if is_gamepad_held(.RIGHT_SHOULDER) do zoom += 1
	if is_gamepad_held(.LEFT_SHOULDER) do zoom -= 1
	zoom *= speed * delta_time * 4 // a held button covers four wheel notches a second

	// One wheel notch is 120; up pulls the camera in
	zoom -= f32(get_mouse_wheel_value()) / 120 * speed
	return zoom
}

/*The walk asked for: x right, y forward, each -1..1, from WASD or the arrows, the left stick and the d-pad*/
get_movement_input :: proc() -> [2]f32 {
	input:[2]f32

	if is_key_held(.W) || is_key_held(.UP) do input.y += 1
	if is_key_held(.S) || is_key_held(.DOWN) do input.y -= 1
	if is_key_held(.D) || is_key_held(.RIGHT) do input.x += 1
	if is_key_held(.A) || is_key_held(.LEFT) do input.x -= 1

	input += get_thumbstick_value(.LEFT_THUMBSTICK)
	if is_gamepad_held(.DPAD_UP) do input.y += 1
	if is_gamepad_held(.DPAD_DOWN) do input.y -= 1
	if is_gamepad_held(.DPAD_RIGHT) do input.x += 1
	if is_gamepad_held(.DPAD_LEFT) do input.x -= 1

	// Per axis, not by length: tank controls want a diagonal to turn and walk at full speed
	return {clamp(input.x, -1, 1), clamp(input.y, -1, 1)}
}
