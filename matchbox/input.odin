package matchbox

/*
	Input
	-----
	This file contains all input related information.
*/

import "core:log"
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

	// Fingers, and whether they are what is being used. See touch.odin -- most
	// of a UI works on a touch screen without reading any of this, because SDL
	// turns one finger into mouse events.
	touches:      [MAX_TOUCHES]Touch,
	touch_active: bool,
	mouse_dx:   f32, // relative motion since the last poll, right is positive
	mouse_dy:   f32, // relative motion since the last poll, up is positive
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

	mbi.frame += 1

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
	touches_begin_frame()

	// Update absolute mouse position in logical screen space (matches where you draw).
	{
		raw_x, raw_y: f32
		_ = sdl.GetMouseState(&raw_x, &raw_y)

		// SDL reports the pointer in window *points* while everything drawn is in
		// window *pixels*, and on a scaled display those differ. Without this the
		// pointer sits short of where it looks by a quarter on a 125% display --
		// and gets further out the further right and down it goes, which is the
		// kind of wrongness that reads as "the hitboxes are off".
		density := mbi.pixel_density if mbi.pixel_density > 0 else 1
		raw_x *= density
		raw_y *= density

		scale := mbi.draw_scale if mbi.draw_scale > 0 else 1
		x := (raw_x - mbi.draw_offset[0]) / scale
		y := (raw_y - mbi.draw_offset[1]) / scale

		// A device may have both a touch screen and a mouse, so which is in use
		// follows whichever moved last rather than being decided at startup.
		// Compared after the transform, in the space the old value is already in
		// -- against the raw window pixels it would differ every frame under a
		// letterbox and say the mouse had moved when nothing had.
		//
		// Checked only with no finger down, because SDL's synthesised touch-mouse
		// moves the pointer too and would otherwise cancel touch on every drag.
		if (x != mbi.input.mouse.x || y != mbi.input.mouse.y) &&
		   mbi.input.touch_active && get_touch_count() == 0 {
			mbi.input.touch_active = false
		}

		mbi.input.mouse.x = x
		mbi.input.mouse.y = y
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
		case .FINGER_DOWN, .FINGER_UP, .FINGER_MOTION, .FINGER_CANCELED:
			touch_handle_event(event)
		}
	}

	/*
		Frame limiting, against an absolute deadline.

		Two things were wrong with waiting for "the frame time minus however long
		this frame took". The wait went through sdl.Delay, which takes whole
		milliseconds, so a rate that is not a whole number of them -- a Game Boy
		frame is 16.742706 ms -- lost the remainder every frame. And, which
		matters more, nothing ever made up for a wait that came back late: the
		error was measured fresh each frame and any overshoot was simply kept.

		Measured over 180 frames at a Game Boy's 16.742706 ms, that ran 1.4 to
		1.6 percent fast -- about 60.6 fps against a target of 59.7275, and
		repeatable to within a fifth of a percent run to run, so it was the model
		and not noise. The version below comes in at 0.22 percent under.

		So the deadline is absolute and advances by exactly one period whatever
		the last frame cost, which lets a long frame be followed by a short wait
		and leaves the average where it was asked to be. DelayPrecise takes
		nanoseconds and spins down the last fraction rather than handing the whole
		wait to the scheduler.

		The catch-up limit is what keeps that from turning into a stampede. A
		window dragged for two seconds would otherwise leave a deadline two
		seconds in the past and a hundred frames owed, and the loop would run flat
		out with no wait at all trying to serve them. Past four frames behind the
		debt is written off and the deadline starts again from now.
	*/
	if mbi.target_frame_time > 0 && mbi.ts_freq > 0 {
		period := u64(f64(mbi.target_frame_time) * f64(mbi.ts_freq))
		now    := sdl.GetPerformanceCounter()

		switch {
		case mbi.next_frame_ts == 0, now > mbi.next_frame_ts + period * 4:
			mbi.next_frame_ts = now + period

		case now < mbi.next_frame_ts:
			wait := f64(mbi.next_frame_ts - now) / f64(mbi.ts_freq)
			sdl.DelayPrecise(u64(wait * 1_000_000_000))
			fallthrough

		case:
			mbi.next_frame_ts += period
		}
	}

	// After every event has been seen, so a tap that starts and ends inside one
	// frame is still visible to the frame it happened in.
	touches_end_frame()

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

/*
	How far the pointer moved since the last `poll_events`, rather than where it
	is now.

	**Y is positive upward here**, which is the opposite of `get_mouse_position`
	and of everything drawn. That is deliberate and it is the older of the two
	conventions in this file: this is a look delta, and a look delta reading
	"up is up" is what a camera wants. `get_gamepad_stick` says the same thing
	from the other side.

	The units are whatever SDL reports for relative motion, which is not the
	same as the pixels `get_mouse_position` is converted into -- so this is a
	number to multiply by a sensitivity, not one to add to a position.

	Useful mostly with `set_cursor_locked`, since a pointer against the edge of
	the screen stops producing motion while a locked one never runs out of room.
*/
get_mouse_delta :: proc() -> [2]f32 {
	return {mbi.input.mouse_dx, mbi.input.mouse_dy}
}

/*
	Hides the pointer and keeps it in the window, reporting only how far it
	moved. What every first-person camera wants, and raylib's `DisableCursor`.

	`get_mouse_delta` keeps working and is the only thing that does:
	`get_mouse_position` freezes where the pointer was, because there is no
	longer a pointer position to report. Unlock before drawing a menu.

	Not to be confused with `capture_mouse`, which is a UI notion -- one widget
	claiming the pointer for a frame so the things underneath do not also answer
	the click. This one is the operating system's cursor.
*/
set_cursor_locked :: proc(locked: bool) {
	if !sdl.SetWindowRelativeMouseMode(mbi.window, locked) {
		log.errorf("could not %s the cursor: %s", "lock" if locked else "unlock", sdl.GetError())
	}
}

// Whether the pointer is currently locked to the window.
is_cursor_locked :: proc() -> bool {
	return sdl.GetWindowRelativeMouseMode(mbi.window)
}

/*
	Which key closes the window, or `.UNKNOWN` for none.

	ESC by default, which is wrong for any game where ESC is how you get the
	mouse pointer back -- every mouse-look game in Matchbox calls this with
	`.UNKNOWN` as its first line and handles ESC itself.
*/
set_escape_key :: proc(key:sdl.Scancode) {
	mbi.input.escape_key = key
}

// True only on the frame the key went down. What a jump or a menu choice
// wants: it fires once however long the key is held.
is_key_pressed :: proc(key:sdl.Scancode) -> bool {
	return mbi.input.keys[key].pressed
}

// True every frame the key is down, including the first. What movement wants,
// and what to multiply by `get_delta_time`.
is_key_held :: proc(key:sdl.Scancode) -> bool {
	return mbi.input.keys[key].pressing
}

// True only on the frame the key came back up. The pair of `is_key_pressed`,
// for a charge-and-release or anything that acts on let-go.
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

// Stops accepting typing, and takes down the on-screen keyboard a phone put
// up. Safe to call when text input was never started.
end_text_input :: proc() {
	if !mbi.input.text_open do return

	_ = sdl.StopTextInput(mbi.window)
	mbi.input.text_open = false
}

// Whether typing is being accepted. What a game checks before treating a
// keypress as a game control rather than as a character someone typed.
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

// True only on the frame the button went down. The mouse's `is_key_pressed`.
is_mouse_pressed :: proc(button:Mouse_Button) -> bool {
	return mbi.input.mouse.buttons[button].pressed
}

// True every frame the button is down. What a drag reads.
is_mouse_held :: proc(button:Mouse_Button) -> bool {
	return mbi.input.mouse.buttons[button].pressing
}

// True only on the frame the button came back up. What ends a drag, and what
// a click-to-place wants rather than the press.
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
	Hands the pointer back, for a widget that claimed it and has now drawn the
	thing it was protecting.

	A modal is what needs this. It takes the pointer at the top of the frame so
	nothing underneath answers a click, and then has to give it back before it
	draws its own buttons -- which ask is_mouse_captured() like every other button
	and would otherwise be as dead as the screen behind them.
*/
release_mouse :: proc() {
	mbi.input.mouse.captured = false
}

/*
	Whether something above has already claimed the pointer this frame.

	Ask before acting on a click, and before treating the pointer as hovering
	anything, in any screen that has a widget capable of opening out over it.
	Order matters: this only knows about widgets that have already run, so the
	thing that opens out has to be drawn before the things it covers.
*/
is_mouse_captured :: proc() -> bool {
	return mbi.input.mouse.captured
}

