package matchbox

/*
	Gamepad
	-------
	Up to MAX_GAMEPADS controllers, addressed by a slot index that behaves like
	a player number: the first pad to connect is 0, the second is 1, and a pad
	that disconnects frees its slot for the next one to take.

	Everything here goes through SDL's *gamepad* API rather than its joystick
	API, which is the difference between "button 3" and `.NORTH`. SDL carries a
	mapping database for the controllers people actually own, so an Xbox pad, a
	DualSense and a Switch Pro controller all report the same buttons in the
	same places without the game knowing which is which.

	Buttons come from events, like keys and mouse buttons, because that is what
	makes `pressed` and `released` exact edges. Axes are read straight from the
	device each frame instead: an axis has no edge to miss, and polling cannot
	fall behind the way a queue can.
*/

import "core:math"

import sdl "vendor:sdl3"

// Four is the usual ceiling for people sitting on one couch, and keeping it
// fixed means slots can be a plain array with no allocation behind them.
MAX_GAMEPADS :: 4

Gamepad_Stick :: enum {
	LEFT,
	RIGHT,
}

Gamepad_Trigger :: enum {
	LEFT,
	RIGHT,
}

/*
	Defaults lifted from XInput, which is where the numbers everyone else uses
	came from: 7849/32767 for a stick and 30/255 for a trigger. They are a
	starting point rather than a truth -- a worn thumbstick needs more, and a
	twin-stick shooter often wants less.
*/
GAMEPAD_STICK_DEADZONE    :: 0.24
GAMEPAD_TRIGGER_THRESHOLD :: 0.12

Gamepad :: struct {
	handle:    ^sdl.Gamepad,
	id:        sdl.JoystickID,
	connected: bool,

	buttons: #sparse[sdl.GamepadButton]Key_State,

	// Normalised to -1..1, or 0..1 for the triggers, with no deadzone applied.
	// get_gamepad_stick is the one that cleans them up; this is here for the
	// cases that want the untouched value.
	axes: #sparse[sdl.GamepadAxis]f32,
}

// -----------------------------------------------------------------------
// Wiring -- called by init, poll_events and cleanup
// -----------------------------------------------------------------------

/*
	Picks up controllers that were already plugged in when the program started.

	SDL does send GAMEPAD_ADDED for those as well, but not until the first
	poll_events, and a game is entitled to ask which pads exist before it has
	drawn a frame -- a menu that says "press A" wants to know now.
*/
@(private)
gamepads_init :: proc() {
	count: i32
	ids := sdl.GetGamepads(&count)
	if ids == nil do return
	defer sdl.free(rawptr(ids))

	for i in 0 ..< count {
		gamepad_open(ids[i])
	}
}

@(private)
gamepad_open :: proc(id: sdl.JoystickID) {
	// Already known: SDL can report the same device twice across the initial
	// enumeration and the event that follows it.
	for &pad in mbi.input.gamepads {
		if pad.connected && pad.id == id do return
	}

	slot := -1
	for &pad, i in mbi.input.gamepads {
		if !pad.connected {
			slot = i
			break
		}
	}
	if slot < 0 do return // more controllers than slots; the extras are ignored

	handle := sdl.OpenGamepad(id)
	if handle == nil do return

	mbi.input.gamepads[slot] = Gamepad{
		handle    = handle,
		id        = id,
		connected = true,
	}
}

@(private)
gamepad_close :: proc(id: sdl.JoystickID) {
	for &pad in mbi.input.gamepads {
		if !pad.connected || pad.id != id do continue

		sdl.CloseGamepad(pad.handle)

		// Zeroed rather than just flagged: a pad that is pulled out mid-press
		// would otherwise leave `pressing` set forever, and whoever takes the
		// slot next would inherit it.
		pad = Gamepad{}
		return
	}
}

@(private)
gamepads_cleanup :: proc() {
	for &pad in mbi.input.gamepads {
		if pad.connected do sdl.CloseGamepad(pad.handle)
		pad = Gamepad{}
	}
}

// Clears the per-frame edges and re-reads every axis. Mirrors what poll_events
// does for keys and mouse buttons at the top of a frame.
@(private)
gamepads_begin_frame :: proc() {
	for &pad in mbi.input.gamepads {
		for &button in pad.buttons {
			button.pressed  = false
			button.released = false
		}

		if !pad.connected do continue

		for axis in sdl.GamepadAxis {
			if axis == .INVALID do continue

			raw := f32(sdl.GetGamepadAxis(pad.handle, axis)) / 32767.0

			// -32768 normalises to just past -1, which would let a stick pushed
			// hard into its corner report a magnitude above full deflection.
			pad.axes[axis] = clamp(raw, -1, 1)
		}
	}
}

@(private)
gamepad_handle_event :: proc(event: sdl.Event) {
	#partial switch event.type {
	case .GAMEPAD_ADDED:
		gamepad_open(event.gdevice.which)

	case .GAMEPAD_REMOVED:
		gamepad_close(event.gdevice.which)

	case .GAMEPAD_BUTTON_DOWN, .GAMEPAD_BUTTON_UP:
		e := event.gbutton
		for &pad in mbi.input.gamepads {
			if !pad.connected || pad.id != e.which do continue

			button := sdl.GamepadButton(e.button)
			if e.down {
				pad.buttons[button].pressed  = true
				pad.buttons[button].pressing = true
			} else {
				pad.buttons[button].pressing = false
				pad.buttons[button].released = true
			}
			return
		}
	}
}

// -----------------------------------------------------------------------
// Queries
// -----------------------------------------------------------------------

// Whether a controller is in this slot. Slots are stable while a pad stays
// plugged in, so this is also "does player N have a controller".
is_gamepad_connected :: proc(pad: int) -> bool {
	if pad < 0 || pad >= MAX_GAMEPADS do return false
	return mbi.input.gamepads[pad].connected
}

// How many controllers are connected. Note this is a count, not a highest
// slot: unplugging pad 0 while pad 1 stays put leaves the count at 1 and pad 1
// where it was. Loop over MAX_GAMEPADS with is_gamepad_connected rather than
// over this.
get_gamepad_count :: proc() -> int {
	count := 0
	for pad in mbi.input.gamepads {
		if pad.connected do count += 1
	}
	return count
}

// What the controller calls itself -- "Xbox Series X Controller" and such.
// Empty when the slot is unoccupied. Useful for a config screen, and for
// telling two pads apart when both are plugged in.
get_gamepad_name :: proc(pad: int) -> string {
	if !is_gamepad_connected(pad) do return ""

	name := sdl.GetGamepadName(mbi.input.gamepads[pad].handle)
	if name == nil do return ""
	return string(name)
}

is_gamepad_button_pressed :: proc(pad: int, button: sdl.GamepadButton) -> bool {
	if !is_gamepad_connected(pad) do return false
	return mbi.input.gamepads[pad].buttons[button].pressed
}

is_gamepad_button_held :: proc(pad: int, button: sdl.GamepadButton) -> bool {
	if !is_gamepad_connected(pad) do return false
	return mbi.input.gamepads[pad].buttons[button].pressing
}

is_gamepad_button_released :: proc(pad: int, button: sdl.GamepadButton) -> bool {
	if !is_gamepad_connected(pad) do return false
	return mbi.input.gamepads[pad].buttons[button].released
}

/*
	One axis, normalised, with no deadzone applied.

	Raw on purpose. A stick at rest does not read zero, so anything steering
	off this needs its own deadzone -- which is what get_gamepad_stick is for.
	Reach for this when you want the untreated number.
*/
get_gamepad_axis :: proc(pad: int, axis: sdl.GamepadAxis) -> f32 {
	if !is_gamepad_connected(pad) do return 0
	return mbi.input.gamepads[pad].axes[axis]
}

/*
	A thumbstick as a direction, with the deadzone taken out.

	The deadzone is radial rather than per-axis, and this matters more than it
	sounds. Testing each axis on its own carves a *square* hole out of the
	middle of the stick's travel, so a stick pushed diagonally can sit outside
	the deadzone on both axes while barely being off centre, and a slow
	diagonal push snaps to one axis before the other lets go.

	The magnitude is also rescaled to run from 0 at the edge of the deadzone up
	to 1 at full deflection, rather than jumping straight to the deadzone value
	the moment it is crossed. Without that, a character starts moving at a
	quarter speed instead of from a standstill.

	Y is positive downward, matching the screen and world coordinates
	everything else here draws in, so `position += get_gamepad_stick(...) *
	speed` moves the way the stick is pushed. This is the opposite of
	`mouse_dy`, which is a relative look delta and reads better with up
	positive.
*/
get_gamepad_stick :: proc(pad: int, stick: Gamepad_Stick) -> [2]f32 {
	if !is_gamepad_connected(pad) do return {0, 0}

	raw: [2]f32
	switch stick {
	case .LEFT:  raw = {get_gamepad_axis(pad, .LEFTX),  get_gamepad_axis(pad, .LEFTY)}
	case .RIGHT: raw = {get_gamepad_axis(pad, .RIGHTX), get_gamepad_axis(pad, .RIGHTY)}
	}

	magnitude := math.sqrt(raw.x * raw.x + raw.y * raw.y)
	deadzone  := mbi.input.gamepad_deadzone

	if magnitude <= deadzone || magnitude <= 0 do return {0, 0}

	scaled := min((magnitude - deadzone) / (1 - deadzone), 1)
	return raw / magnitude * scaled
}

/*
	A trigger's travel, 0 at rest and 1 fully depressed.

	Below the threshold it reads 0, and above it the value is rescaled from the
	threshold up to 1 for the same reason the sticks are -- so a trigger begins
	from nothing rather than snapping to a tenth of its range.
*/
get_gamepad_trigger :: proc(pad: int, trigger: Gamepad_Trigger) -> f32 {
	if !is_gamepad_connected(pad) do return 0

	value: f32
	switch trigger {
	case .LEFT:  value = get_gamepad_axis(pad, .LEFT_TRIGGER)
	case .RIGHT: value = get_gamepad_axis(pad, .RIGHT_TRIGGER)
	}

	threshold := mbi.input.gamepad_trigger_threshold
	if value <= threshold do return 0

	return min((value - threshold) / (1 - threshold), 1)
}

/*
	How far a stick has to move before it counts, as a fraction of its full
	travel. Applies to every pad.

	Worth exposing because the right number is a property of the hardware in
	someone's hands, not of the game: a controller with worn sticks drifts and
	needs more, and a game that lives on small precise movements wants less.
*/
set_gamepad_deadzone :: proc(deadzone: f32) {
	mbi.input.gamepad_deadzone = clamp(deadzone, 0, 0.95)
}

set_gamepad_trigger_threshold :: proc(threshold: f32) {
	mbi.input.gamepad_trigger_threshold = clamp(threshold, 0, 0.95)
}

/*
	Shakes the controller. `low` and `high` are 0..1 and drive the two motors
	-- low is the heavy rumble, high is the sharper one -- and it stops on its
	own after `duration_ms`.

	Does nothing on a pad with no motors, which includes a good many third
	party controllers, so it cannot be relied on to be felt.
*/
set_gamepad_rumble :: proc(pad: int, low: f32, high: f32, duration_ms: u32) {
	if !is_gamepad_connected(pad) do return

	to_u16 :: proc(v: f32) -> u16 {
		return u16(clamp(v, 0, 1) * 65535)
	}

	_ = sdl.RumbleGamepad(
		mbi.input.gamepads[pad].handle,
		to_u16(low), to_u16(high), duration_ms,
	)
}
