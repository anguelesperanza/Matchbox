package matchbox

/*
	Touch
	-----
	Fingers, for the platforms that have them.

	**Most of a matchbox program already works on a touch screen without using
	any of this.** SDL turns a single finger into mouse events by default, so
	`get_mouse_position`, `is_mouse_pressed(.LEFT)` and therefore every button,
	slider, scroll view and dropdown answer a tap as they answer a click. That is
	worth stating plainly because it decides what this file is for: it is not
	needed to make a UI usable, it is needed for the things one synthesised mouse
	cannot express.

	Which is two things. Multiple fingers -- a pinch, a two-finger pan, a second
	thumb on a gamepad-style control -- and knowing that touch is what is
	happening, so a screen can stop offering things that depend on a pointer
	existing while nothing is pressed.

	That last one is the real design problem, and it is not solved here because
	it cannot be solved by a framework. `hover_dwell` means "the pointer has
	rested on this for a while", which on a touch screen is a long press: it
	works, and it is a different gesture with different expectations. A button's
	hover fill only appears while a finger is down, which is correct and also
	means it can never be a preview of what a tap would do. A tooltip that opens
	on dwell becomes a tooltip that opens on long-press and covers the thing
	being pressed. None of those are broken; they are decisions, and
	`touch_active` is how a screen makes them.
*/

import sdl "vendor:sdl3"

// Ten, which is as many fingers as anybody has. Fixed, so the slots cost no
// allocation and a game can loop over them without asking how many there are.
MAX_TOUCHES :: 10

/*
	One finger. Held in a fixed slot for as long as it is down.

	`position` is in the same logical screen space as the mouse -- letterbox and
	pixel density already taken off -- so it goes straight to `point_in_rect` and
	everything built on it. SDL reports fingers normalised 0..1 across the
	window; that conversion happens once, here, rather than in every caller.
*/
Touch :: struct {
	id:       sdl.FingerID,
	position: [2]f32,
	delta:    [2]f32, // movement since the last frame, in the same space
	pressure: f32,    // 0..1, and 0 on hardware that does not measure it

	down:     bool, // currently on the glass
	pressed:  bool, // went down this frame
	released: bool, // came up this frame
	active:   bool, // this slot holds a finger at all
}

/*
	Whether input is currently coming from touch.

	Set by the first finger and cleared by any real mouse movement, so a device
	with both -- a laptop with a touch screen, a tablet with a trackpad -- follows
	whichever was used last rather than being decided once at startup.

	This is what a screen should ask before offering something that needs a
	pointer to exist while nothing is pressed: a hover preview, a tooltip on
	dwell, a cursor drawn by the game.
*/
touch_active :: proc() -> bool {
	return mbi.input.touch_active
}

// How many fingers are down. Zero most of the time, and the thing to check
// before reading any slot.
get_touch_count :: proc() -> int {
	count := 0
	for t in mbi.input.touches do if t.active do count += 1
	return count
}

/*
	A finger by slot, 0 to MAX_TOUCHES-1.

	Slots are stable while a finger stays down, so a gesture can follow one
	across frames by its slot -- the same arrangement as the gamepads. `active`
	is false for a slot nobody is touching, and the rest of it means nothing
	then.
*/
get_touch :: proc(slot: int) -> Touch {
	if slot < 0 || slot >= MAX_TOUCHES do return {}
	return mbi.input.touches[slot]
}

// The first finger down, which is what a single-touch game wants without
// caring which slot it landed in. `ok` is false when nothing is being touched.
get_primary_touch :: proc() -> (touch: Touch, ok: bool) {
	for t in mbi.input.touches {
		if t.active do return t, true
	}
	return {}, false
}

// Whether a slot's finger went down this frame.
is_touch_pressed :: proc(slot: int) -> bool {
	return get_touch(slot).pressed
}

// Whether a slot's finger is on the glass.
is_touch_down :: proc(slot: int) -> bool {
	return get_touch(slot).down
}

// Whether a slot's finger came up this frame.
is_touch_released :: proc(slot: int) -> bool {
	return get_touch(slot).released
}

/*
	The distance between the first two fingers, and how much it changed this
	frame. `ok` is false with fewer than two down.

	Pinch is the one gesture that genuinely needs more than one finger and is
	tedious enough to get right that it is worth having once. `change` is what a
	zoom multiplies by; `distance` is there for anything wanting the absolute.
*/
get_pinch :: proc() -> (distance: f32, change: f32, ok: bool) {
	first, second: Touch
	found := 0

	for t in mbi.input.touches {
		if !t.active do continue
		if found == 0 do first = t
		if found == 1 do second = t
		found += 1
		if found == 2 do break
	}

	if found < 2 do return 0, 0, false

	now  := vec_length(second.position - first.position)
	then := vec_length((second.position - second.delta) - (first.position - first.delta))

	return now, now - then, true
}

@(private)
vec_length :: proc(v: [2]f32) -> f32 {
	return sdl.sqrtf(v.x * v.x + v.y * v.y)
}

// -----------------------------------------------------------------------
// Fed by poll_events
// -----------------------------------------------------------------------

// Clears the per-frame flags and the movement, keeping whichever fingers are
// still down. Called at the top of poll_events, like the keys and the buttons.
@(private)
touches_begin_frame :: proc() {
	for &t in mbi.input.touches {
		t.pressed  = false
		t.released = false
		t.delta    = {0, 0}
	}
}

/*
	Takes one finger event.

	A released finger keeps its slot until the end of the frame so that the frame
	it lifted on can still see where it was and that it lifted at all -- freeing
	the slot immediately would make a tap that starts and ends inside one frame
	invisible.
*/
@(private)
touch_handle_event :: proc(event: sdl.Event) {
	finger := event.tfinger

	// SDL reports 0..1 across the window; everything here works in the same
	// logical space the mouse does.
	position := [2]f32{
		finger.x * f32(mbi.window_width),
		finger.y * f32(mbi.window_height),
	}
	position = window_to_logical(position)

	#partial switch event.type {
	case .FINGER_DOWN:
		if slot := touch_slot_for(finger.fingerID, true); slot >= 0 {
			t := &mbi.input.touches[slot]
			t^ = Touch{
				id       = finger.fingerID,
				position = position,
				pressure = finger.pressure,
				down     = true,
				pressed  = true,
				active   = true,
			}
			mbi.input.touch_active = true
		}

	case .FINGER_MOTION:
		if slot := touch_slot_for(finger.fingerID, false); slot >= 0 {
			t := &mbi.input.touches[slot]
			t.delta    += position - t.position
			t.position  = position
			t.pressure  = finger.pressure
			mbi.input.touch_active = true
		}

	case .FINGER_UP, .FINGER_CANCELED:
		if slot := touch_slot_for(finger.fingerID, false); slot >= 0 {
			t := &mbi.input.touches[slot]
			t.position = position
			t.down     = false
			t.released = true
			// `active` stays until touches_end_frame, so this frame can see it.
		}
	}
}

// Frees the slots of fingers that lifted during the frame just drawn. Called at
// the end of poll_events, after everything has had a chance to see them.
@(private)
touches_end_frame :: proc() {
	for &t in mbi.input.touches {
		if t.active && !t.down do t.active = false
	}
}

// The slot holding this finger, or a free one when `claim` is set. -1 when
// there is no room, which means more than ten fingers and can be ignored.
@(private)
touch_slot_for :: proc(id: sdl.FingerID, claim: bool) -> int {
	for t, i in mbi.input.touches {
		if t.active && t.id == id do return i
	}

	if claim {
		for t, i in mbi.input.touches {
			if !t.active do return i
		}
	}

	return -1
}

/*
	Window pixels into the space games draw in.

	The same transform poll_events applies to the mouse, which is why fingers and
	the pointer end up comparable. Not shared with it only because the mouse
	arrives in points and needs the density applied first, while a finger arrives
	as a fraction of the window and does not.
*/
@(private)
window_to_logical :: proc(position: [2]f32) -> [2]f32 {
	scale := mbi.draw_scale if mbi.draw_scale > 0 else 1
	return (position - mbi.draw_offset) / scale
}
