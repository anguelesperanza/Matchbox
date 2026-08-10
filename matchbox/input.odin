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
//
// `wheel` is per-frame, not absolute: it is the scroll that happened during
// this poll_events and is back to zero on the next one. Positive y is away
// from the user, positive x is to the right.
Mouse :: struct {
	x:       f32,
	y:       f32,
	wheel:   [2]f32,
	buttons: [Mouse_Button]Key_State,
}

Mouse_Button :: enum {
	LEFT,
	MIDDLE,
	RIGHT,
}

Input :: struct {
	keys:       #sparse[sdl.Scancode]Key_State,
	mouse:      Mouse,
	mouse_dx:   f32, // pixels/dpi (inches), right is positive
	mouse_dy:   f32, // pixels/dpi (inches), up is positive
	escape_key: sdl.Scancode, // closes the window when pressed
}

// Processes SDL events, updates input state, and calculates delta_time.
// Call this at the very start of your game loop, before any game logic.
poll_events :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before poll_events")

	for &key in mbi.input.keys {
		key.pressed = false
		key.released = false
	}
	for &btn in mbi.input.mouse.buttons {
		btn.pressed = false
		btn.released = false
	}
	mbi.input.mouse_dx = 0
	mbi.input.mouse_dy = 0
	mbi.input.mouse.wheel = {0, 0}

	// Update absolute mouse position in logical screen space (matches where you draw).
	{
		raw_x, raw_y: f32
		_ = sdl.GetMouseState(&raw_x, &raw_y)
		scale := mbi.draw_scale if mbi.draw_scale > 0 else 1
		mbi.input.mouse.x = (raw_x - mbi.draw_offset[0]) / scale
		mbi.input.mouse.y = (raw_y - mbi.draw_offset[1]) / scale
	}

	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			mbi.running = false
		case .WINDOW_CLOSE_REQUESTED:
			{
				if event.window.windowID == sdl.GetWindowID(mbi.window) {
					mbi.running = false
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

				if valid {
					if event.type == .MOUSE_BUTTON_DOWN {
						mbi.input.mouse.buttons[mb].pressed  = true
						mbi.input.mouse.buttons[mb].pressing = true
					} else if event.type == .MOUSE_BUTTON_UP {
						mbi.input.mouse.buttons[mb].pressing = false
						mbi.input.mouse.buttons[mb].released = true
					}
				}
			}
		case .KEY_DOWN, .KEY_UP:
			{
				event := event.key
				if event.repeat do break

				if event.scancode == mbi.input.escape_key do mbi.running = false

				if event.type == .KEY_DOWN {
					mbi.input.keys[event.scancode].pressed = true
					mbi.input.keys[event.scancode].pressing = true
				} else {
					mbi.input.keys[event.scancode].pressing = false
					mbi.input.keys[event.scancode].released = true
				}
			}
		case .MOUSE_MOTION:
			{
				event := event.motion
				mbi.input.mouse_dx += event.xrel
				mbi.input.mouse_dy -= event.yrel // In sdl, up is negative
			}
		case .MOUSE_WHEEL:
			{
				event := event.wheel

				// A FLIPPED wheel (natural scrolling) reports the opposite sign,
				// so undo it here and hand games one consistent direction.
				scroll := [2]f32{event.x, event.y}
				if event.direction == .FLIPPED do scroll = -scroll

				mbi.input.mouse.wheel += scroll
			}
		}
	}

	if mbi.target_frame_time > 0 {
		current_ts := sdl.GetPerformanceCounter()
		elapsed :=
			f32(f64((current_ts - mbi.now_ts) * 1000) / f64(mbi.ts_freq)) /
			1000.0
		if elapsed < mbi.target_frame_time {
			sleep_ms := u32((mbi.target_frame_time - elapsed) * 1000)
			if sleep_ms > 0 do sdl.Delay(sleep_ms)
		}
	}

	last_ts := mbi.now_ts
	mbi.now_ts = sdl.GetPerformanceCounter()

	// Seconds elapsed since the previous poll_events, clamped so a slow/stalled
	// frame can't teleport everything. Without this, delta_time stays 0 and the
	// whole game appears frozen on the first frame.
	mbi.delta_time = min(
		mbi.max_delta_time,
		f32(f64((mbi.now_ts - last_ts) * 1000) / f64(mbi.ts_freq)) / 1000.0,
	)
}

// Mouse position in logical screen space, matching the coordinates you draw
// with. For world-space coordinates under an active camera, use
// get_mouse_world_pos instead.
get_mouse_position :: proc() -> [2]f32 {
	return {mbi.input.mouse.x, mbi.input.mouse.y}
}

// How far the wheel was scrolled during this frame, zero when it was not
// touched. Positive is away from the user -- the usual "zoom in" direction.
// Horizontal scroll, from tilt wheels and trackpads, is in `.x`.
get_mouse_wheel :: proc() -> [2]f32 {
	return mbi.input.mouse.wheel
}

set_escape_key :: proc(key:sdl.Scancode) {
	mbi.input.escape_key = key
}

is_key_pressed :: proc(key:sdl.Scancode) -> bool {
	return mbi.input.keys[key].pressed
}

is_key_held :: proc(key:sdl.Scancode) -> bool {
	return mbi.input.keys[key].pressing
}

is_key_released :: proc(key:sdl.Scancode) -> bool {
	return mbi.input.keys[key].released
}

is_mouse_pressed :: proc(button:Mouse_Button) -> bool {
	return mbi.input.mouse.buttons[button].pressed
}

is_mouse_held :: proc(button:Mouse_Button) -> bool {
	return mbi.input.mouse.buttons[button].pressing
}

is_mouse_released :: proc(button:Mouse_Button) -> bool {
	return mbi.input.mouse.buttons[button].released
}

