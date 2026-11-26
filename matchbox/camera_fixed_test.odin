package matchbox

/*
	Which shot is on screen, when it cuts, and what the camera does with it. None of these touch `mbi`.
*/

import "core:testing"

// Two rooms side by side along X, overlapping by 2 where they meet (x 4 to 6)
@(private="file")
two_rooms :: proc() -> Fixed_Camera {
	rig := create_fixed_camera()
	add_fixed_camera_shot(&rig, {position = {-4, 3, 8}, target = {-4, 0, 0}, zone_min = {-10, -1, -10}, zone_max = {6, 3, 10}})
	add_fixed_camera_shot(&rig, {position = {14, 3, 8}, target = {14, 0, 0}, fov_y = 50, zone_min = {4, -1, -10}, zone_max = {20, 3, 10}})
	return rig
}

@(test)
first_shot_is_on_screen_as_soon_as_it_is_added :: proc(t:^testing.T) {
	rig := two_rooms()
	testing.expect_value(t, rig.camera.position, [3]f32{-4, 3, 8})
	testing.expect_value(t, rig.camera.target, [3]f32{-4, 0, 0})
	testing.expect_value(t, rig.camera.fov_y, f32(70)) // a zero fov reads as 70
}

@(test)
walking_into_the_second_zone_cuts_once :: proc(t:^testing.T) {
	rig := two_rooms()
	follow_fixed_camera(&rig, {0, 0, 0})
	testing.expect_value(t, rig.cut, false)

	follow_fixed_camera(&rig, {7, 0, 0})
	testing.expect_value(t, rig.shot, 1)
	testing.expect_value(t, rig.cut, true)
	testing.expect_value(t, rig.camera.position, [3]f32{14, 3, 8})
	testing.expect_value(t, rig.camera.fov_y, f32(50))

	// True for exactly the frame that changed
	follow_fixed_camera(&rig, {8, 0, 0})
	testing.expect_value(t, rig.cut, false)
}

// Inside the overlap the shot on screen keeps it, so standing on the seam does not strobe
@(test)
the_shot_on_screen_keeps_the_screen_inside_an_overlap :: proc(t:^testing.T) {
	rig := two_rooms()
	follow_fixed_camera(&rig, {5, 0, 0})
	testing.expect_value(t, rig.shot, 0)
	for _ in 0 ..< 10 {
		follow_fixed_camera(&rig, {5, 0, 0})
		testing.expect_value(t, rig.cut, false)
	}

	// Entered from the far side, shot 1 holds although shot 0 also contains the point
	rig = two_rooms()
	follow_fixed_camera(&rig, {10, 0, 0})
	follow_fixed_camera(&rig, {5, 0, 0})
	testing.expect_value(t, rig.shot, 1)
}

@(test)
a_character_outside_every_zone_keeps_the_last_shot :: proc(t:^testing.T) {
	rig := two_rooms()
	follow_fixed_camera(&rig, {500, 0, 0})
	testing.expect_value(t, rig.shot, 0)
	testing.expect_value(t, rig.cut, false)
}

@(test)
a_zone_written_backwards_still_contains_its_box :: proc(t:^testing.T) {
	shot := Camera_Shot{zone_min = {10, 3, 10}, zone_max = {-10, -1, -10}}
	testing.expect(t, is_point_in_camera_shot(shot, {0, 0, 0}))
	testing.expect(t, is_point_in_camera_shot(shot, {10, 3, 10})) // edges included
	testing.expect(t, !is_point_in_camera_shot(shot, {10.01, 0, 0}))
}

@(test)
a_track_shot_turns_to_the_character_plus_the_focus_offset :: proc(t:^testing.T) {
	rig := create_fixed_camera(focus_offset = {0, 1.5, 0})
	add_fixed_camera_shot(&rig, {position = {0, 4, 10}, target = {0, 0, 0}, aim = .TRACK, zone_min = {-20, -1, -20}, zone_max = {20, 3, 20}})
	follow_fixed_camera(&rig, {3, 0, -2})
	testing.expect_value(t, rig.camera.position, [3]f32{0, 4, 10}) // never moves
	testing.expect_value(t, rig.camera.target, [3]f32{3, 1.5, -2})
}

@(test)
shots_beyond_the_capacity_are_refused :: proc(t:^testing.T) {
	rig := create_fixed_camera()
	for _ in 0 ..< MAX_CAMERA_SHOTS do testing.expect(t, add_fixed_camera_shot(&rig, {}) >= 0)
	testing.expect_value(t, add_fixed_camera_shot(&rig, {}), -1)
	testing.expect_value(t, rig.shot_count, MAX_CAMERA_SHOTS)
}

@(test)
a_rig_with_no_shots_does_nothing :: proc(t:^testing.T) {
	rig := create_fixed_camera()
	follow_fixed_camera(&rig, {1, 2, 3})
	testing.expect_value(t, rig.cut, false)
}
