package matchbox

/*
	Tests for the finger bookkeeping.

	In the package rather than beside it, because the interesting parts --
	claiming a slot, holding it across frames, freeing it after the frame it
	lifted on -- are private, and because feeding events straight to the handler
	is the only way to test any of this without a touch screen.

	`@(test)` procedures are only compiled by `odin test`, so none of this is in
	a normal build. Run with:

		odin test matchbox -define:ODIN_TEST_THREADS=1
*/

import "core:testing"

import sdl "vendor:sdl3"

// The handler reads the window size and the letterbox transform. Setting them
// directly is what keeps these tests off the GPU: no init, no window, no driver.
@(private = "file")
setup :: proc(width, height: i32) {
	mbi.window_width  = width
	mbi.window_height = height
	mbi.draw_scale    = 1
	mbi.draw_offset   = {0, 0}
	mbi.input.touches = {}
	mbi.input.touch_active = false
}

@(private = "file")
finger :: proc(kind: sdl.EventType, id: u64, nx, ny: f32) {
	e: sdl.Event
	e.type              = kind
	e.tfinger.fingerID  = sdl.FingerID(id)
	e.tfinger.x         = nx
	e.tfinger.y         = ny
	e.tfinger.pressure  = 1
	touch_handle_event(e)
}

@(test)
test_touch_down_and_position :: proc(t: ^testing.T) {
	setup(800, 600)

	testing.expect(t, get_touch_count() == 0, "nothing should be touching yet")
	testing.expect(t, !is_touch_active(), "is_touch_active should start false")

	touches_begin_frame()
	finger(.FINGER_DOWN, 1, 0.5, 0.5)

	touch, ok := get_primary_touch()
	testing.expect(t, ok && get_touch_count() == 1, "one finger should be down")

	// SDL reports 0..1 across the window; this is the conversion callers rely on.
	testing.expect_value(t, touch.position, [2]f32{400, 300})
	testing.expect(t, touch.pressed && touch.down && !touch.released,
		"a finger should be pressed and down on the frame it lands")
	testing.expect(t, is_touch_active(), "is_touch_active should follow a finger")
}

@(test)
test_letterbox_is_applied :: proc(t: ^testing.T) {
	setup(800, 600)
	mbi.draw_scale  = 2
	mbi.draw_offset = {100, 50}

	touches_begin_frame()
	finger(.FINGER_DOWN, 1, 0.5, 0.5)

	touch, _ := get_primary_touch()

	// (400,300) window pixels, minus the offset, divided by the scale -- the same
	// transform the mouse gets, which is what makes fingers and pointer
	// comparable.
	testing.expect_value(t, touch.position, [2]f32{150, 125})
}

@(test)
test_slots_are_stable_and_freed :: proc(t: ^testing.T) {
	setup(800, 600)

	touches_begin_frame()
	finger(.FINGER_DOWN, 1, 0.25, 0.5)
	finger(.FINGER_DOWN, 2, 0.75, 0.5)
	testing.expect(t, get_touch_count() == 2, "two fingers should take two slots")

	// pressed is per-frame; down is not
	touches_begin_frame()
	testing.expect(t, !get_touch(0).pressed && get_touch(0).down,
		"pressed should clear while down stays")

	// a lifted finger is still readable during the frame it lifted on
	finger(.FINGER_UP, 1, 0.25, 0.5)
	lifted := get_touch(0)
	testing.expect(t, lifted.active && lifted.released && !lifted.down,
		"a lifted finger should still be readable this frame")
	testing.expect(t, get_touch(1).down, "the other finger should be untouched")

	touches_end_frame()
	testing.expect(t, get_touch_count() == 1, "the slot should be free next frame")
}

@(test)
test_tap_inside_one_frame_survives :: proc(t: ^testing.T) {
	setup(800, 600)

	// Down and up between two poll_events. Freeing the slot on FINGER_UP rather
	// than at the end of the frame would lose this entirely.
	touches_begin_frame()
	finger(.FINGER_DOWN, 9, 0.25, 0.25)
	finger(.FINGER_UP,   9, 0.25, 0.25)

	seen := false
	for i in 0 ..< MAX_TOUCHES {
		s := get_touch(i)
		if s.active && s.pressed && s.released do seen = true
	}
	testing.expect(t, seen, "a tap inside one frame should still be seen")
}

@(test)
test_pinch :: proc(t: ^testing.T) {
	setup(800, 600)

	touches_begin_frame()
	finger(.FINGER_DOWN, 1, 0.25, 0.5) // x = 200
	finger(.FINGER_DOWN, 2, 0.50, 0.5) // x = 400

	distance, _, ok := get_pinch()
	testing.expect(t, ok, "two fingers should give a pinch")
	testing.expectf(t, abs(distance - 200) < 0.01, "gap should be 200, got %v", distance)

	touches_begin_frame()
	finger(.FINGER_MOTION, 2, 0.625, 0.5) // x = 500, so 100 further out

	distance2, change, _ := get_pinch()
	testing.expectf(t, abs(distance2 - 300) < 0.01, "gap should be 300, got %v", distance2)
	testing.expectf(t, abs(change - 100) < 0.01, "change should be 100, got %v", change)
}

@(test)
test_pinch_needs_two_fingers :: proc(t: ^testing.T) {
	setup(800, 600)

	touches_begin_frame()
	finger(.FINGER_DOWN, 1, 0.5, 0.5)

	_, _, ok := get_pinch()
	testing.expect(t, !ok, "one finger should not report a pinch")
}

@(test)
test_out_of_range_slots_are_safe :: proc(t: ^testing.T) {
	setup(800, 600)

	// Reading a slot nobody is touching, or one that does not exist, has to be
	// harmless -- callers loop over MAX_TOUCHES without checking first.
	testing.expect(t, !get_touch(-1).active, "a negative slot should be inert")
	testing.expect(t, !get_touch(MAX_TOUCHES).active, "a slot past the end should be inert")
	testing.expect(t, !get_touch(9999).active, "a wild slot should be inert")
	testing.expect(t, !is_touch_pressed(-1) && !is_touch_down(99) && !is_touch_released(-5),
		"the predicates should be false for slots that do not exist")
}
