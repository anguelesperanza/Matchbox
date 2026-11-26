#+build windows

package matchbox

/*
	The camera inputs, driven with synthetic state (`mbi.keys_held`, `mbi.left_thumbstick_axis`, the mouse
	motion and the clock) rather than by hand. They write `mbi`, so each takes the lock and puts back what it changed.
*/

import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:testing"

@(private="file")
mbi_lock:sync.Mutex

@(private="file")
Saved_State :: struct {
	keys_held:#sparse [Key]bool,
	left_stick:[2]f32,
	right_stick:[2]f32,
	gamepad_held:bit_set[Button],
	mouse_held:[Mouse]bool,
	mouse_wheel:i16,
	motion:Mouse_Motion,
	clock:Clock,
}

@(private="file")
save_state :: proc() -> Saved_State {
	sync.mutex_lock(&mbi_lock)
	return {mbi.keys_held, mbi.left_thumbstick_axis, mbi.right_thumbstick_axis, mbi.gamepad_held, mbi.mouse_held, mbi.mouse_wheel_value, mbi.mouse_motion, mbi.clock}
}

@(private="file")
restore_state :: proc(saved:Saved_State) {
	mbi.keys_held = saved.keys_held
	mbi.left_thumbstick_axis = saved.left_stick
	mbi.right_thumbstick_axis = saved.right_stick
	mbi.gamepad_held = saved.gamepad_held
	mbi.mouse_held = saved.mouse_held
	mbi.mouse_wheel_value = saved.mouse_wheel
	mbi.mouse_motion = saved.motion
	mbi.clock = saved.clock
	sync.mutex_unlock(&mbi_lock)
}

@(private="file")
near :: proc(a:[3]f32, b:[3]f32) -> bool {
	return linalg.length(a - b) < 1e-4
}

@(test)
mouse_motion_is_zero_on_the_frame_a_drag_starts :: proc(t:^testing.T) {
	motion:Mouse_Motion
	update_mouse_motion(&motion, {100, 50}, true)
	testing.expect_value(t, motion.delta, [2]f32{0, 0}) // no previous position yet: a touch must not jump from 0, 0

	update_mouse_motion(&motion, {110, 45}, true)
	testing.expect_value(t, motion.delta, [2]f32{10, -5})

	update_mouse_motion(&motion, {200, 200}, false) // finger lifted
	testing.expect_value(t, motion.delta, [2]f32{0, 0})
	update_mouse_motion(&motion, {5, 5}, true) // a new touch far away
	testing.expect_value(t, motion.delta, [2]f32{0, 0})
}

@(test)
movement_input_reads_keys_stick_and_dpad_and_clamps_each_axis :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.keys_held = {}
	mbi.left_thumbstick_axis = {}
	mbi.gamepad_held = {}
	testing.expect_value(t, get_movement_input(), [2]f32{0, 0})

	mbi.keys_held[.W] = true
	testing.expect_value(t, get_movement_input(), [2]f32{0, 1})
	mbi.keys_held[.D] = true
	testing.expect_value(t, get_movement_input(), [2]f32{1, 1}) // a diagonal is not shortened here: tank wants both axes

	// W and the stick together are not twice as fast
	mbi.left_thumbstick_axis = {0, 1}
	testing.expect_value(t, get_movement_input(), [2]f32{1, 1})

	mbi.keys_held = {}
	mbi.left_thumbstick_axis = {-0.5, 0}
	mbi.gamepad_held = {.DPAD_DOWN}
	testing.expect_value(t, get_movement_input(), [2]f32{-0.5, -1})
}

@(test)
look_input_turns_by_the_drag_and_the_right_stick :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.mouse_held = {}
	mbi.mouse_motion = {}
	mbi.right_thumbstick_axis = {}

	// Moving the pointer without a button down does not look: the cursor is on its way to a menu
	mbi.mouse_motion.delta = {100, 0}
	testing.expect_value(t, get_camera_look_input(0.003, 2.5, 1.0 / 60), [2]f32{0, 0})

	// Dragging right by 100 px at 0.003 rad/px turns right: yaw down by 0.3. Dragging up looks up
	mbi.mouse_held[.RIGHT] = true
	look := get_camera_look_input(0.003, 2.5, 1.0 / 60)
	testing.expectf(t, abs(look.x + 0.3) < 1e-6 && look.y == 0, "got %v", look)
	mbi.mouse_motion.delta = {0, -100}
	look = get_camera_look_input(0.003, 2.5, 1.0 / 60)
	testing.expectf(t, abs(look.y - 0.3) < 1e-6, "got %v", look)

	// A full right push for one second at 2.5 rad/s: right is a smaller yaw, up looks up
	mbi.mouse_held = {}
	mbi.right_thumbstick_axis = {1, 1}
	look = get_camera_look_input(0.003, 2.5, 1)
	testing.expect_value(t, look, [2]f32{-2.5, 2.5})
}

@(test)
zoom_input_reads_shoulders_and_the_wheel :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.gamepad_held = {}
	mbi.mouse_wheel_value = 0
	testing.expect_value(t, get_camera_zoom_input(1, 0.25), f32(0))

	mbi.gamepad_held = {.RIGHT_SHOULDER}
	testing.expect_value(t, get_camera_zoom_input(1, 0.25), f32(1)) // out: four units a second
	mbi.gamepad_held = {.LEFT_SHOULDER}
	testing.expect_value(t, get_camera_zoom_input(1, 0.25), f32(-1))

	// One notch up (+120) pulls the camera in by `speed`
	mbi.gamepad_held = {}
	mbi.mouse_wheel_value = 120
	testing.expect_value(t, get_camera_zoom_input(2, 0.25), f32(-2))
}

@(test)
first_person_walks_where_the_keys_and_the_view_say :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.keys_held = {}
	mbi.left_thumbstick_axis = {}
	mbi.right_thumbstick_axis = {}
	mbi.gamepad_held = {}
	mbi.mouse_held = {}
	mbi.clock.delta_time = 0.5

	rig := create_first_person_camera(eye_offset = {0, 1.7, 0})
	position := [3]f32{}
	mbi.keys_held[.W] = true
	walk_first_person_camera(&rig, &position, 4, 0.5)
	testing.expect(t, near(position, {0, 0, -2}), "W walks down -Z at yaw 0")
	testing.expect(t, near(rig.camera.position, {0, 1.7, -2}))

	// Turn left a quarter (a stick push to -X would turn right): the same key now walks down -X
	rig.look.yaw = math.PI * 0.5
	walk_first_person_camera(&rig, &position, 4, 0.5)
	testing.expect(t, near(position, {-2, 0, -2}))
}

@(test)
third_person_zoom_and_steering_follow_the_input :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.keys_held = {}
	mbi.left_thumbstick_axis = {}
	mbi.right_thumbstick_axis = {}
	mbi.mouse_held = {}
	mbi.mouse_wheel_value = 0
	mbi.clock.delta_time = 0.25
	mbi.gamepad_held = {.RIGHT_SHOULDER}

	rig := create_third_person_camera(distance = 6)
	update_third_person_input(&rig)
	testing.expectf(t, abs(rig.distance - 7) < 1e-5, "R pulled the camera out to %v", rig.distance)

	mbi.gamepad_held = {}
	mbi.keys_held[.D] = true // CAMERA steering: right of the camera, +X at yaw 0
	update_third_person_input(&rig)
	testing.expect(t, near(rig.move, {1, 0, 0}))
	follow_third_person_camera(&rig, {}, 10) // a long step so the body arrives: facing east is a yaw of -90
	testing.expectf(t, abs(rig.facing + math.PI * 0.5) < 1e-4, "facing %v", rig.facing)

	// CHARACTER steering reads the keys against the heading, not the camera
	rig.steering = .CHARACTER
	rig.look.yaw = 2 // the camera looks somewhere else entirely
	rig.facing = 0
	update_third_person_input(&rig)
	testing.expect(t, near(rig.move, {1, 0, 0}))
}
