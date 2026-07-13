package matchbox

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Input
// -----------------------------------------------------------------------

is_key_down :: proc(matchbox_info: ^MatchboxInfo, key: sdl.Scancode) -> bool {
	return matchbox_info.keys_down[key]
}

is_key_pressed :: proc(matchbox_info: ^MatchboxInfo, key: sdl.Scancode) -> bool {
	return matchbox_info.keys_pressed[key]
}

is_mouse_pressed :: proc(matchbox_info: ^MatchboxInfo, button: sdl.MouseButtonFlag) -> bool {
	if sdl.HasMouse() {
		return matchbox_info.mouse.buttons_pressed[button]
	}
	return false
}

is_mouse_held :: proc(matchbox_info: ^MatchboxInfo, button: sdl.MouseButtonFlag) -> bool {
	if sdl.HasMouse() {
		raw_x, raw_y: f32
		state := sdl.GetMouseState(&raw_x, &raw_y)
		return button in state
	}
	return false
}
