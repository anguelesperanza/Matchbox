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

Input :: struct {
	pressing_right_click: bool,
	left_click_pressed:   bool, // One-shot flag for left mouse button press
	keys:                 #sparse[sdl.Scancode]Key_State,
	mouse_dx:             f32, // pixels/dpi (inches), right is positive
	mouse_dy:             f32, // pixels/dpi (inches), up is positive
}

// Processes SDL events, updates input state, and calculates delta_time.
// Call this at the very start of your game loop, before any game logic.

poll_events :: proc(matchbox_info: ^MatchboxInfo) {
	for &key in matchbox_info.input.keys {
		key.pressed = false
		key.released = false
	}
	matchbox_info.input.mouse_dx = 0
	matchbox_info.input.mouse_dy = 0
	matchbox_info.input.left_click_pressed = false

	for &key in matchbox_info.input.keys {
		key.pressed = false
		key.released = false
	}
	matchbox_info.input.mouse_dx = 0
	matchbox_info.input.mouse_dy = 0
	matchbox_info.input.left_click_pressed = false

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
				if event.type == .MOUSE_BUTTON_DOWN {
					if event.button == sdl.BUTTON_RIGHT {
						matchbox_info.input.pressing_right_click = true
					} else if event.button == sdl.BUTTON_LEFT {
						matchbox_info.input.left_click_pressed = true
					}
				} else if event.type == .MOUSE_BUTTON_UP {
					if event.button == sdl.BUTTON_RIGHT {
						matchbox_info.input.pressing_right_click = false
					}
				}
			}
		case .KEY_DOWN, .KEY_UP:
			{
				event := event.key
				if event.repeat do break

				if event.scancode == matchbox_info.escape_key do matchbox_info.running = false

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
}

set_escape_key :: proc(matchbox_info:^MatchboxInfo, key:sdl.Scancode) {
	matchbox_info.escape_key = key
}
