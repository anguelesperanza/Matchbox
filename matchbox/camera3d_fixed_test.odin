package matchbox

/*
	Fixed camera shots -- which shot is on screen
	---------------------------------------------
	The failures here are all quiet ones. A zone written backwards never cuts;
	a missing overlap rule strobes between two shots on a seam; a gap between
	zones sends the camera somewhere useless. None of them crash, and all of them
	look like a level-design problem rather than a camera one, so the rules are
	pinned down here.

	No GPU is needed: the rig only writes a `Camera3D`.
*/

import "core:testing"

/*
	Two rooms side by side along x, meeting at x = 0, with their zones
	overlapping by half a unit either side of the doorway. Room A's camera sits
	in its far corner; room B's looks back from the other end.
*/
@(private="file")
two_rooms :: proc() -> Fixed_Camera {
	rig := create_fixed_camera()

	fixed_camera_add_shot(&rig, Camera_Shot{
		position = {-9, 4, -9}, target = {-5, 0, 0},
		zone_min = {-10, -1, -10}, zone_max = {0.5, 3, 10},
	})
	fixed_camera_add_shot(&rig, Camera_Shot{
		position = {9, 4, 9}, target = {5, 0, 0},
		zone_min = {-0.5, -1, -10}, zone_max = {10, 3, 10},
	})

	return rig
}

// The camera is a real camera as soon as there is a shot to put it at, rather
// than the zero Camera3D -- whose position and target are the same point, and
// whose view matrix is therefore built from nothing.
@(test)
test_fixed_camera_seats_the_first_shot_on_add :: proc(t: ^testing.T) {
	rig := two_rooms()
	defer destroy(&rig)

	testing.expect_value(t, rig.shot, 0)
	testing.expect_value(t, rig.camera.position, [3]f32{-9, 4, -9})
	testing.expect_value(t, rig.camera.target, [3]f32{-5, 0, 0})
	testing.expect(t, !rig.cut, "adding a shot is not a cut")
}

// Walk into the other room: the shot changes, `cut` says so for that frame,
// and is false again on the next.
@(test)
test_fixed_camera_cuts_to_the_zone_the_subject_is_in :: proc(t: ^testing.T) {
	rig := two_rooms()
	defer destroy(&rig)

	fixed_camera_follow(&rig, {-5, 0, 0})
	testing.expect_value(t, rig.shot, 0)
	testing.expect(t, !rig.cut, "staying in the first shot's zone cut")

	fixed_camera_follow(&rig, {5, 0, 0})
	testing.expect_value(t, rig.shot, 1)
	testing.expect(t, rig.cut, "walking into another zone did not report a cut")
	testing.expect_value(t, rig.camera.position, [3]f32{9, 4, 9})
	testing.expect_value(t, rig.camera.target, [3]f32{5, 0, 0})

	fixed_camera_follow(&rig, {5.1, 0, 0})
	testing.expect_value(t, rig.shot, 1)
	testing.expect(t, !rig.cut, "cut stayed true on the frame after the cut")
}

/*
	The overlap is a buffer in both directions. Standing in it keeps whichever
	shot was already on screen; only leaving that shot's own zone cuts.

	The rule this replaced in thought -- "the earliest zone containing the
	character wins" -- would pass the first half of this test and fail the walk
	back: at x = 0 both zones contain the character and shot 0 is earlier, so
	it would cut back to A while the character was still inside B.
*/
@(test)
test_fixed_camera_holds_its_shot_through_the_overlap :: proc(t: ^testing.T) {
	rig := two_rooms()
	defer destroy(&rig)

	// A to B.
	for x in ([]f32{-3, -0.4, 0, 0.4}) {
		fixed_camera_follow(&rig, {x, 0, 0})
		testing.expectf(t, rig.shot == 0 && !rig.cut, "at x = %v, going east, shot %v cut %v", x, rig.shot, rig.cut)
	}

	fixed_camera_follow(&rig, {0.6, 0, 0})
	testing.expect(t, rig.shot == 1 && rig.cut, "leaving room A's zone did not cut to B")

	// And back again: the overlap now holds B.
	for x in ([]f32{0.4, 0, -0.4}) {
		fixed_camera_follow(&rig, {x, 0, 0})
		testing.expectf(t, rig.shot == 1 && !rig.cut, "at x = %v, going west, shot %v cut %v", x, rig.shot, rig.cut)
	}

	fixed_camera_follow(&rig, {-0.6, 0, 0})
	testing.expect(t, rig.shot == 0 && rig.cut, "leaving room B's zone did not cut to A")
}

// Outside every zone, the last shot stays. A gap in the zones is a level bug,
// and a camera that stays put shows it.
@(test)
test_fixed_camera_keeps_the_last_shot_outside_every_zone :: proc(t: ^testing.T) {
	rig := two_rooms()
	defer destroy(&rig)

	fixed_camera_follow(&rig, {5, 0, 0})
	fixed_camera_follow(&rig, {50, 0, 0})

	testing.expect_value(t, rig.shot, 1)
	testing.expect(t, !rig.cut, "leaving every zone reported a cut")
	testing.expect_value(t, rig.camera.position, [3]f32{9, 4, 9})
}

// Starting outside the first shot's zone is a cut on the very first follow.
@(test)
test_fixed_camera_first_follow_can_cut :: proc(t: ^testing.T) {
	rig := two_rooms()
	defer destroy(&rig)

	fixed_camera_follow(&rig, {5, 0, 0})

	testing.expect_value(t, rig.shot, 1)
	testing.expect(t, rig.cut, "the first follow into shot 1 did not report a cut")
}

// A tracking shot looks at the character's feet plus the focus offset, from
// wherever it was placed; a fixed shot ignores the character entirely.
@(test)
test_fixed_camera_track_aims_at_the_subject :: proc(t: ^testing.T) {
	rig := create_fixed_camera(focus_offset = {0, 1.5, 0})
	defer destroy(&rig)

	fixed_camera_add_shot(&rig, Camera_Shot{
		position = {0, 3, 10}, target = {0, 0, 0}, aim = .TRACK,
		zone_min = {-5, -1, -5}, zone_max = {5, 3, 5},
	})

	fixed_camera_follow(&rig, {2, 0, -1})
	testing.expect_value(t, rig.camera.position, [3]f32{0, 3, 10})
	testing.expect_value(t, rig.camera.target, [3]f32{2, 1.5, -1})

	rig.shots[0].aim = .FIXED
	fixed_camera_follow(&rig, {2, 0, -1})
	testing.expect_value(t, rig.camera.target, [3]f32{0, 0, 0})
}

// The corners are a box, whichever way round they were written.
@(test)
test_camera_shot_zone_corners_either_way_round :: proc(t: ^testing.T) {
	forwards  := Camera_Shot{zone_min = {-1, -1, -1}, zone_max = {1, 1, 1}}
	backwards := Camera_Shot{zone_min = {1, 1, 1}, zone_max = {-1, -1, -1}}
	mixed     := Camera_Shot{zone_min = {1, -1, 1}, zone_max = {-1, 1, -1}}

	for shot in ([]Camera_Shot{forwards, backwards, mixed}) {
		testing.expect(t, camera_shot_contains(shot, {0.5, 0, -0.5}), "a point inside the box was not contained")
		testing.expect(t, camera_shot_contains(shot, {1, 1, 1}), "a corner of the box was not contained")
		testing.expect(t, !camera_shot_contains(shot, {1.01, 0, 0}), "a point outside the box was contained")
	}
}

// A written-out-of-range shot with nothing to replace it leaves the camera
// alone rather than indexing past the end of the shots.
@(test)
test_fixed_camera_survives_a_bad_shot_index :: proc(t: ^testing.T) {
	rig := two_rooms()
	defer destroy(&rig)

	before := rig.camera
	rig.shot = 7
	fixed_camera_follow(&rig, {50, 0, 0})

	testing.expect_value(t, rig.camera, before)
}

// The zero value takes shots, and a rig can be destroyed twice.
@(test)
test_fixed_camera_zero_value_and_double_destroy :: proc(t: ^testing.T) {
	rig: Fixed_Camera

	fixed_camera_follow(&rig, {0, 0, 0})
	testing.expect_value(t, len(rig.shots), 0)

	fixed_camera_add_shot(&rig, Camera_Shot{position = {1, 2, 3}, target = {0, 0, 0}})
	testing.expect_value(t, rig.camera.position, [3]f32{1, 2, 3})

	destroy(&rig)
	destroy(&rig)
	testing.expect_value(t, len(rig.shots), 0)
}
