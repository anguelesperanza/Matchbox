package matchbox

/*
	Input
	-----
	This file contains all input related information.
*/

import "core:strings"

import sdl "vendor:sdl3"

Key_State :: struct {
	pressed:  bool,
	pressing: bool,
	released: bool,

	// Like `pressed`, but also set each time the key auto-repeats while held.
	//
	// Kept apart from `pressed` rather than folded into it, because the two
	// answer different questions and code written against one would be wrong
	// with the other. Firing a weapon wants the first press only; deleting a
	// character wants every repeat, or holding backspace removes one letter
	// and stops.
	repeated: bool,
}

// How much text a single frame can accept. Typing cannot get near this -- it
// exists for a paste, and for the pathological case of an IME committing a
// paragraph at once.
MAX_TEXT_INPUT :: 1024

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

	// Whether something on top has claimed the pointer this frame. Per-frame
	// like `wheel`, and false again on the next poll_events.
	//
	// Drawing here is immediate, so what is drawn last is on top and nothing
	// knows what is above it. A widget that opens out over other things -- a
	// dropdown's list is the case this was added for -- claims the pointer,
	// and whatever is underneath asks before acting on a click of its own.
	// Without it, the click that picks an option out of an open list also
	// lands on whatever that list was covering.
	captured: bool,
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

	// What was typed during this poll_events, as utf-8. Per-frame like
	// mouse.wheel, and empty again on the next one.
	//
	// Typed rather than pressed: this is what the keyboard layout and any IME
	// decided the person meant, so it is already the right character on an
	// AZERTY keyboard and already handles shift, dead keys and accents. None
	// of that can be recovered from a scancode without reimplementing it.
	text:        [MAX_TEXT_INPUT]u8,
	text_length: int,
	text_open:   bool, // whether text input is currently being accepted

	// Controllers, by slot. See gamepad.odin -- slots behave like player
	// numbers and a disconnected pad frees its own.
	gamepads:                  [MAX_GAMEPADS]Gamepad,
	gamepad_deadzone:          f32,
	gamepad_trigger_threshold: f32,
}

// Processes SDL events, updates input state, and calculates delta_time.
// Call this at the very start of your game loop, before any game logic.
poll_events :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before poll_events")

	for &key in mbi.input.keys {
		key.pressed  = false
		key.released = false
		key.repeated = false
	}
	mbi.input.text_length = 0
	for &btn in mbi.input.mouse.buttons {
		btn.pressed = false
		btn.released = false
	}
	mbi.input.mouse_dx = 0
	mbi.input.mouse_dy = 0
	mbi.input.mouse.wheel = {0, 0}
	mbi.input.mouse.captured = false
	gamepads_begin_frame()

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

				// An auto-repeat is a real keystroke to anything editing text
				// and a phantom one to everything else, so it sets `repeated`
				// and nothing more. Everything below this point is about the
				// key genuinely changing state.
				if event.repeat {
					if event.type == .KEY_DOWN do mbi.input.keys[event.scancode].repeated = true
					break
				}

				if event.scancode == mbi.input.escape_key do mbi.running = false

				if event.type == .KEY_DOWN {
					mbi.input.keys[event.scancode].pressed = true
					mbi.input.keys[event.scancode].pressing = true
					mbi.input.keys[event.scancode].repeated = true
				} else {
					mbi.input.keys[event.scancode].pressing = false
					mbi.input.keys[event.scancode].released = true
				}
			}
		case .TEXT_INPUT:
			{
				// The string belongs to SDL and is only good for as long as
				// this event is, so it is copied out here rather than kept
				text  := string(event.text.text)
				room  := MAX_TEXT_INPUT - mbi.input.text_length
				taken := min(len(text), room)

				copy(mbi.input.text[mbi.input.text_length:], text[:taken])
				mbi.input.text_length += taken
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
		case .GAMEPAD_ADDED, .GAMEPAD_REMOVED, .GAMEPAD_BUTTON_DOWN, .GAMEPAD_BUTTON_UP:
			gamepad_handle_event(event)
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

// Whether the key fired this frame, counting auto-repeat while it is held.
//
// This is the one to use for anything that should keep happening while a key
// is down at the system's own repeat rate: deleting characters, stepping
// through a list. Use is_key_pressed when only the first press should count.
is_key_repeated :: proc(key:sdl.Scancode) -> bool {
	return mbi.input.keys[key].repeated
}

// -----------------------------------------------------------------------
// Text input
// -----------------------------------------------------------------------

/*
	Starts accepting typed text, and returns it from get_text_input.

	Not optional dressing for a text box: this is what tells the operating
	system a person is about to type. Mobile on-screen keyboards appear on it,
	and IME candidate windows -- how anybody types Japanese, Chinese or Korean
	-- only open between this and end_text_input.

	Off by default, because while it is on the platform may swallow keystrokes
	to build characters out of them, which is not what a game wants during play.
*/
begin_text_input :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before begin_text_input")
	if mbi.input.text_open do return

	// A false here means the platform declined -- a headless session, or no
	// text input service. Nothing to do about it, and refusing to set the flag
	// would only make callers ask forever.
	_ = sdl.StartTextInput(mbi.window)
	mbi.input.text_open = true
}

end_text_input :: proc() {
	if !mbi.input.text_open do return

	_ = sdl.StopTextInput(mbi.window)
	mbi.input.text_open = false
}

is_text_input_open :: proc() -> bool {
	return mbi.input.text_open
}

/*
	What was typed this frame, as utf-8, empty when nothing was.

	Already the right character: the keyboard layout, shift, dead keys and any
	IME have all had their say by the time it arrives. Do not try to rebuild
	this from scancodes -- that road ends in reimplementing every keyboard
	layout in the world.

	The result points into per-frame storage and is replaced by the next
	poll_events. Copy it if it needs to outlive the frame.
*/
get_text_input :: proc() -> string {
	return string(mbi.input.text[:mbi.input.text_length])
}

/*
	The clipboard's contents, or "" when it holds no text.

	The caller owns the result. SDL hands back a copy it wants freeing, so this
	clones into `allocator` and gives SDL's copy straight back rather than
	leaving ownership split across the boundary.
*/
get_clipboard_text :: proc(allocator := context.allocator) -> string {
	raw := sdl.GetClipboardText()
	if raw == nil do return ""
	defer sdl.free(rawptr(raw))

	return strings.clone(string(cstring(rawptr(raw))), allocator)
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

/*
	Claims the pointer for whatever is drawn on top, for the rest of this frame.

	Called by a widget that has opened out over the screen. Cleared by the next
	poll_events, so it never has to be given back.
*/
capture_mouse :: proc() {
	mbi.input.mouse.captured = true
}

/*
	Whether something above has already claimed the pointer this frame.

	Ask before acting on a click, and before treating the pointer as hovering
	anything, in any screen that has a widget capable of opening out over it.
	Order matters: this only knows about widgets that have already run, so the
	thing that opens out has to be drawn before the things it covers.
*/
mouse_captured :: proc() -> bool {
	return mbi.input.mouse.captured
}

