package matchbox

/*
	Input
	-----
	This file contains all input related information.
*/

import "gpu"
import sdl "vendor:sdl3"

Key_State :: struct {
	pressed:  bool,
	pressing: bool,
	released: bool,
}

// Absolute mouse state, updated every poll_events. `x`/`y` are in logical
// screen space (draw_offset/draw_scale applied), matching where you draw.
Mouse :: struct {
	x:       f32,
	y:       f32,
	buttons: [Mouse_Button]Key_State,
}

Mouse_Button :: enum {
	LEFT,
	MIDDLE,
	RIGHT,
}

Input :: struct {
	keys:                 #sparse[sdl.Scancode]Key_State,
	mouse:                Mouse,
	mouse_dx:             f32, // pixels/dpi (inches), right is positive
	mouse_dy:             f32, // pixels/dpi (inches), up is positive
	escape_key:           sdl.Scancode, // closes the window when pressed
	pressing_right_click: bool,
	left_click_pressed:   bool, // One-shot flag for left mouse button press
}

// Processes SDL events, updates input state, and calculates delta_time.
// Call this at the very start of your game loop, before any game logic.
poll_events :: proc(matchbox_info: ^MatchboxInfo) {
	for &key in matchbox_info.input.keys {
		key.pressed = false
		key.released = false
	}
	for &btn in matchbox_info.input.mouse.buttons {
		btn.pressed = false
		btn.released = false
	}
	matchbox_info.input.mouse_dx = 0
	matchbox_info.input.mouse_dy = 0
	matchbox_info.input.left_click_pressed = false

	// Update absolute mouse position in logical screen space (matches where you draw).
	{
		raw_x, raw_y: f32
		_ = sdl.GetMouseState(&raw_x, &raw_y)
		scale := matchbox_info.draw_scale if matchbox_info.draw_scale > 0 else 1
		matchbox_info.input.mouse.x = (raw_x - matchbox_info.draw_offset[0]) / scale
		matchbox_info.input.mouse.y = (raw_y - matchbox_info.draw_offset[1]) / scale
	}

	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			matchbox_info.running = false
		case .WINDOW_CLOSE_REQUESTED:
			{
				if event.window.windowID == sdl.GetWindowID(matchbox_info.window) {
					matchbox_info.running = false
				}
			}
		// Input events
		case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
			{
				event := event.button

				mb: Mouse_Button
				valid := true
				switch event.button {
				case sdl.BUTTON_LEFT:   mb = .LEFT
				case sdl.BUTTON_MIDDLE: mb = .MIDDLE
				case sdl.BUTTON_RIGHT:  mb = .RIGHT
				case:                   valid = false
				}

				if event.type == .MOUSE_BUTTON_DOWN {
					if valid {
						matchbox_info.input.mouse.buttons[mb].pressed = true
						matchbox_info.input.mouse.buttons[mb].pressing = true
					}
					if event.button == sdl.BUTTON_RIGHT {
						matchbox_info.input.pressing_right_click = true
					} else if event.button == sdl.BUTTON_LEFT {
						matchbox_info.input.left_click_pressed = true
					}
				} else if event.type == .MOUSE_BUTTON_UP {
					if valid {
						matchbox_info.input.mouse.buttons[mb].pressing = false
						matchbox_info.input.mouse.buttons[mb].released = true
					}
					if event.button == sdl.BUTTON_RIGHT {
						matchbox_info.input.pressing_right_click = false
					}
				}
			}
		case .KEY_DOWN, .KEY_UP:
			{
				event := event.key
				if event.repeat do break

				if event.scancode == matchbox_info.input.escape_key do matchbox_info.running = false

				if event.type == .KEY_DOWN {
					matchbox_info.input.keys[event.scancode].pressed = true
					matchbox_info.input.keys[event.scancode].pressing = true
				} else {
					matchbox_info.input.keys[event.scancode].pressing = false
					matchbox_info.input.keys[event.scancode].released = true
				}
			}
		case .MOUSE_MOTION:
			{
				event := event.motion
				matchbox_info.input.mouse_dx += event.xrel
				matchbox_info.input.mouse_dy -= event.yrel // In sdl, up is negative
			}
		}
	}

	if matchbox_info.target_frame_time > 0 {
		current_ts := sdl.GetPerformanceCounter()
		elapsed :=
			f32(f64((current_ts - matchbox_info.now_ts) * 1000) / f64(matchbox_info.ts_freq)) /
			1000.0
		if elapsed < matchbox_info.target_frame_time {
			sleep_ms := u32((matchbox_info.target_frame_time - elapsed) * 1000)
			if sleep_ms > 0 do sdl.Delay(sleep_ms)
		}
	}

	last_ts := matchbox_info.now_ts
	matchbox_info.now_ts = sdl.GetPerformanceCounter()

	// Seconds elapsed since the previous poll_events, clamped so a slow/stalled
	// frame can't teleport everything. Without this, delta_time stays 0 and the
	// whole game appears frozen on the first frame.
	matchbox_info.delta_time = min(
		matchbox_info.max_delta_time,
		f32(f64((matchbox_info.now_ts - last_ts) * 1000) / f64(matchbox_info.ts_freq)) / 1000.0,
	)
}

set_escape_key :: proc(matchbox_info:^MatchboxInfo, key:sdl.Scancode) {
	matchbox_info.input.escape_key = key
}

is_key_pressed :: proc(matchbox_info:^MatchboxInfo, key:sdl.Scancode) -> bool {
	return matchbox_info.input.keys[key].pressed
}

is_key_held :: proc(matchbox_info:^MatchboxInfo, key:sdl.Scancode) -> bool {
	return matchbox_info.input.keys[key].pressing
}

is_key_released :: proc(matchbox_info:^MatchboxInfo, key:sdl.Scancode) -> bool {
	return matchbox_info.input.keys[key].released
}

is_mouse_pressed :: proc(matchbox_info:^MatchboxInfo, button:Mouse_Button) -> bool {
	return matchbox_info.input.mouse.buttons[button].pressed
}

is_mouse_held :: proc(matchbox_info:^MatchboxInfo, button:Mouse_Button) -> bool {
	return matchbox_info.input.mouse.buttons[button].pressing
}

is_mouse_released :: proc(matchbox_info:^MatchboxInfo, button:Mouse_Button) -> bool {
	return matchbox_info.input.mouse.buttons[button].released
}

