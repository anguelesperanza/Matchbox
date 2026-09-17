package level

/*
	Cameras on entities, without a GPU
	-----------------------------------
	Where a camera stands and which way it looks, that a parent carries it, and
	that the fields left at zero are the ones Matchbox fills in.

	The aim is checked by pointing a camera at a known direction and asserting
	on the vector, not by reading the quaternion back: a rotation written
	another way is the same rotation, and the thing that matters is where the
	camera ends up looking.
*/

import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"

import mb ".."

/*
	An entity name the level owns.

	`destroy_level` frees every entity's name with the level's allocator, so a
	name written as a literal in a test is the executable's own memory handed
	to `free` -- which a tracking allocator reports as a bad free. Cloning here
	keeps the test honest about who owns what, which is the same thing the
	editor does when it names an entity.
*/
@(private = "file")
owned :: proc(level: ^Level, name: string) -> string {
	return strings.clone(name, level_allocator(level))
}

@(private)
expect_direction :: proc(t: ^testing.T, got, want: [3]f32, what: string, loc := #caller_location) {
	// Normalised on both sides, then compared by distance: two unit vectors
	// within a thousandth of each other are the same direction.
	a := linalg.normalize(got)
	b := linalg.normalize(want)
	testing.expectf(t, linalg.length(a - b) < 1e-3, "%s: got %v, want %v", what, a, b, loc = loc)
}

@(private)
turn_y :: proc(degrees: f32) -> [4]f32 {
	q := linalg.quaternion_from_euler_angles_f32(0, math.to_radians(degrees), 0, .XYZ)
	return {q.x, q.y, q.z, q.w}
}

@(test)
test_a_camera_looks_down_its_entity_s_minus_z :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	append(&level.entities, Entity{
		id        = 1,
		name      = owned(&level, "shot"),
		transform = {position = {2, 3, -4}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		camera    = Camera_Component{fov = 50, near = 0.2, far = 400},
	})
	update_level(&level)

	camera, ok := camera_from_entity(level.entities[0])
	testing.expect(t, ok, "the entity has a camera")

	testing.expect_value(t, camera.position, [3]f32{2, 3, -4})
	expect_direction(t, camera.target - camera.position, {0, 0, -1}, "an unrotated camera looks down -Z")
	expect_direction(t, camera.up, {0, 1, 0}, "and its up is +Y")

	testing.expect_value(t, camera.fov, 50)
	testing.expect_value(t, camera.near, 0.2)
	testing.expect_value(t, camera.far, 400)

	// Turned a quarter turn about Y: -Z swings to -X. Right-handed, +Y up
	// (math3d.odin), so a positive yaw turns anticlockwise seen from above.
	level.entities[0].transform.rotation = turn_y(90)
	update_level(&level)

	camera, _ = camera_from_entity(level.entities[0])
	expect_direction(t, camera.target - camera.position, {-1, 0, 0}, "turned 90 degrees about Y")
	expect_direction(t, camera.up, {0, 1, 0}, "a yaw does not roll it")

	// Rolled about its own Z: the up tips, the aim does not. A camera that
	// could not be rolled would be a rotate gizmo with a dead axis.
	roll := linalg.quaternion_from_euler_angles_f32(0, 0, math.to_radians(f32(90)), .XYZ)
	level.entities[0].transform.rotation = {roll.x, roll.y, roll.z, roll.w}
	update_level(&level)

	camera, _ = camera_from_entity(level.entities[0])
	expect_direction(t, camera.target - camera.position, {0, 0, -1}, "a roll does not change the aim")
	expect_direction(t, camera.up, {-1, 0, 0}, "but it does tip the up")
}

// A camera under a parent is carried by it, like anything else -- which is what
// makes a camera rig (an empty that swings, a camera hanging off it) work.
@(test)
test_a_camera_is_carried_by_its_parent :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	append(&level.entities,
		Entity{id = 1, name = owned(&level, "rig"), transform = {position = {10, 0, 0}, rotation = turn_y(90), scale = {1, 1, 1}}},
		Entity{id = 2, name = owned(&level, "shot"), parent = 1, transform = {position = {0, 2, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		       camera = Camera_Component{}},
	)
	update_level(&level)

	camera, ok := camera_from_entity(level.entities[1])
	testing.expect(t, ok, "the child has a camera")

	// Two metres up from the rig, which stands at x = 10.
	testing.expect(t, linalg.length(camera.position - [3]f32{10, 2, 0}) < 1e-3,
		"the camera is where its parent puts it")
	expect_direction(t, camera.target - camera.position, {-1, 0, 0}, "and looks the way its parent faces")

	// Scale is ignored: a scaled rig does not change the lens or the aim.
	level.entities[0].transform.scale = {3, 3, 3}
	update_level(&level)

	scaled, _ := camera_from_entity(level.entities[1])
	expect_direction(t, scaled.target - scaled.position, {-1, 0, 0}, "a scaled parent does not turn the camera")
	testing.expect_value(t, scaled.fov, camera.fov)
}

/*
	A component left at zero is the camera `create_camera3d` makes.

	This is why `Camera_Component` has no "configured" flag: there is no
	unconfigured state. `camera3d_defaults` fills the zeros in on the way to
	the matrix, and `camera_settings` fills the same ones in for the editor, so
	the number shown is the number rendered.
*/
@(test)
test_an_unset_camera_is_the_default_camera :: proc(t: ^testing.T) {
	filled := camera_settings(Camera_Component{})
	testing.expect_value(t, filled, CAMERA_DEFAULTS)

	reference := mb.create_camera3d({0, 0, 0}, {0, 0, -1})
	testing.expectf(t, filled.fov == reference.fov, "fov: level says %v, create_camera3d says %v", filled.fov, reference.fov)
	testing.expectf(t, filled.near == reference.near, "near: level says %v, create_camera3d says %v", filled.near, reference.near)
	testing.expectf(t, filled.far == reference.far, "far: level says %v, create_camera3d says %v", filled.far, reference.far)

	// Only the zeros are filled: anything set is left alone.
	set := camera_settings(Camera_Component{fov = 35, near = 1, far = 50})
	testing.expect_value(t, set, Camera_Component{fov = 35, near = 1, far = 50})

	// A far plane behind the near one is not a camera; it takes the default
	// rather than rendering nothing.
	testing.expect_value(t, camera_settings(Camera_Component{near = 10, far = 2}).far, CAMERA_DEFAULTS.far)
}

@(test)
test_a_camera_survives_a_save_and_a_load :: proc(t: ^testing.T) {
	built := create_level()
	defer destroy_level(&built)

	append(&built.entities,
		Entity{id = 1, name = owned(&built, "hall_shot"), transform = {position = {1, 2, 3}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		       camera = Camera_Component{fov = 45, near = 0.3, far = 250}},
		Entity{id = 2, name = owned(&built, "crate"), transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}}},
	)

	data, marshal_err := marshal_level(built, allocator = context.temp_allocator)
	testing.expectf(t, marshal_err == nil, "marshal: %v", marshal_err)

	read, problems, unmarshal_err := unmarshal_level(data, context.temp_allocator)
	defer delete_problems(problems)
	testing.expectf(t, unmarshal_err == nil, "unmarshal: %v", unmarshal_err)
	update_level(&read)

	component, ok := read.entities[0].camera.?
	testing.expect(t, ok, "the camera came back")
	testing.expect_value(t, component, Camera_Component{fov = 45, near = 0.3, far = 250})

	// An entity with no camera has none, rather than a zeroed one: a `Maybe`
	// is written as null, which is what keeps "no camera" and "a camera at all
	// its defaults" apart in the file.
	testing.expect(t, !has_camera(read.entities[1]), "the crate has no camera")

	// And by name, which is how a game finds it.
	camera, found := get_level_camera(&read, "hall_shot")
	testing.expect(t, found, "found by name")
	testing.expect_value(t, camera.position, [3]f32{1, 2, 3})

	_, missing := get_level_camera(&read, "no_such_entity")
	testing.expect(t, !missing, "a name that is not there is not a camera")

	_, not_a_camera := get_level_camera(&read, "crate")
	testing.expect(t, !not_a_camera, "an entity without a camera component is not a camera")
}

/*
	A fixed-angle shot as the editor builds one: an empty group holding a camera
	child and a bounds child, the camera child carrying a shape of its own
	because that is the marker it is drawn as.

	The bounds are deliberately nothing like the camera's own half-metre marker,
	so a shot framed on the wrong shape is a wrong number rather than a near
	miss.
*/
@(private = "file")
add_shot_group :: proc(level: ^Level, id: u64, at: [3]f32, yaw: f32, half: [3]f32) -> Entity_Handle {
	append(&level.entities, Entity{
		id        = id,
		name      = owned(level, "fixed_angle"),
		transform = {position = at, rotation = turn_y(yaw), scale = {1, 1, 1}},
	})
	group := Entity_Handle{index = len(level.entities) - 1, id = id}

	append(&level.entities, Entity{
		id        = id + 1,
		parent    = id,
		name      = owned(level, "camera"),
		transform = {position = {0, 0, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		camera    = Camera_Component{fov = 50, near = 0.1, far = 400},
		shape     = Shape_Component{kind = .BOX, size = {0.5, 0.5, 0.5}},
	})

	append(&level.entities, Entity{
		id        = id + 2,
		parent    = id,
		name      = owned(level, "bounds"),
		transform = {position = {0, 0, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		shape     = Shape_Component{kind = .BOX, size = half},
	})

	return group
}

@(test)
test_a_shot_takes_its_lens_from_the_camera_and_its_zone_from_the_bounds :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	add_shot_group(&level, 1, {3, 2, 1}, 0, {8, 4, 6})
	update_level(&level)

	shot, ok := get_level_camera_shot(&level, "fixed_angle")
	if !testing.expect(t, ok, "a group with a camera and bounds made no shot") do return

	testing.expect_value(t, shot.position, [3]f32{3, 2, 1})
	expect_direction(t, shot.target - shot.position, {0, 0, -1}, "an unturned shot looks down -Z")
	testing.expect_value(t, shot.fov, 50)
	testing.expect_value(t, shot.aim, mb.Camera_Shot_Aim.FIXED)

	// The bounds child's half-extents about the group, and emphatically not the
	// camera child's half-metre marker.
	expect_direction(t, shot.zone_max - shot.zone_min, {8, 4, 6}, "the zone was framed on the wrong shape")
	testing.expect_value(t, shot.zone_min, [3]f32{-5, -2, -5})
	testing.expect_value(t, shot.zone_max, [3]f32{11, 6, 7})

	// The character has to be able to stand in it, or the shot never comes on
	// screen however right its numbers look. Written out rather than called
	// through `mb.camera_shot_contains`, which is private to Matchbox.
	inside := true
	for axis in 0 ..< 3 {
		if shot.position[axis] < shot.zone_min[axis] || shot.position[axis] > shot.zone_max[axis] do inside = false
	}
	testing.expect(t, inside, "the zone does not contain the camera's own spot")

	testing.expect_value(t, mb.Camera_Shot_Aim.TRACK,
		(get_level_camera_shot(&level, "fixed_angle", .TRACK) or_else {}).aim)
}

@(test)
test_each_group_answers_with_its_own_shot :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	// Both groups' children are called `camera` and `bounds`, as duplicating a
	// shot in the editor leaves them.
	append(&level.entities, Entity{
		id        = 100,
		name      = owned(&level, "cameras"),
		transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
	})
	one := add_shot_group(&level, 1, {10, 0, 0}, 0, {1, 1, 1})
	two := add_shot_group(&level, 4, {-10, 0, 0}, 90, {1, 1, 1})
	level.entities[one.index].parent = 100
	level.entities[two.index].parent = 100
	update_level(&level)

	group, found := find_entity(&level, "cameras")
	testing.expect(t, found, "the group holding the shots is not there")

	children := level_children(&level, group, context.temp_allocator)
	defer delete(children, context.temp_allocator)
	if !testing.expect_value(t, len(children), 2) do return

	first, ok_first := camera_shot_from_entity(&level, children[0])
	last, ok_last   := camera_shot_from_entity(&level, children[1])
	testing.expect(t, ok_first && ok_last, "walking the group missed a shot")

	testing.expect_value(t, first.position, [3]f32{10, 0, 0})
	testing.expect_value(t, last.position, [3]f32{-10, 0, 0})

	// A quarter turn about +Y takes -Z to -X (world_test.odin's right-hand
	// rule), so the second shot looks a different way as well as standing
	// somewhere else -- which is what says the group's own transform reached it.
	expect_direction(t, first.target - first.position, {0, 0, -1}, "the first shot's aim")
	expect_direction(t, last.target - last.position, {-1, 0, 0}, "the second shot's aim")
}

@(test)
test_a_group_missing_a_camera_or_a_zone_makes_no_shot :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	// A group whose only child is the camera: a shot with no zone contains
	// nothing, so it would never come on screen and the level-builder would see
	// no camera and no error.
	add_shot_group(&level, 1, {0, 0, 0}, 0, {1, 1, 1})
	bounds := level.entities[2]
	ordered_remove(&level.entities, 2)
	delete(bounds.name, level_allocator(&level))

	// And a group with bounds and no camera at all.
	add_shot_group(&level, 10, {0, 0, 0}, 0, {1, 1, 1})
	level.entities[len(level.entities) - 2].camera = nil

	update_level(&level)

	for handle in ([]Entity_Handle{{index = 0, id = 1}, {index = 2, id = 10}}) {
		_, ok := camera_shot_from_entity(&level, handle)
		testing.expectf(t, !ok, "entity %d made a shot with a part missing", handle.id)
	}

	// So does a name that is nowhere.
	_, nowhere := get_level_camera_shot(&level, "no_such_group")
	testing.expect(t, !nowhere, "a name that is nowhere made a shot")
}

@(test)
test_a_group_carrying_its_own_camera_still_makes_a_shot :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	// The older shape: the camera on the group itself, with one child marking
	// the zone. It has to keep working, or a level built before the split stops
	// loading.
	append(&level.entities, Entity{
		id        = 1,
		name      = owned(&level, "fixed_angle"),
		transform = {position = {0, 1, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		camera    = Camera_Component{fov = 60},
	})
	append(&level.entities, Entity{
		id        = 2,
		parent    = 1,
		name      = owned(&level, "bounds"),
		transform = {position = {0, 0, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		shape     = Shape_Component{kind = .BOX, size = {2, 2, 2}},
	})
	update_level(&level)

	shot, ok := get_level_camera_shot(&level, "fixed_angle")
	if !testing.expect(t, ok, "a group carrying its own camera made no shot") do return

	testing.expect_value(t, shot.position, [3]f32{0, 1, 0})
	testing.expect_value(t, shot.fov, 60)
	testing.expect_value(t, shot.zone_min, [3]f32{-2, -1, -2})
}

@(test)
test_a_camera_component_left_at_zero_reads_back_as_the_angle_it_is_drawn_at :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	group := add_shot_group(&level, 1, {0, 0, 0}, 0, {1, 1, 1})
	level.entities[group.index + 1].camera = Camera_Component{}
	update_level(&level)

	shot, ok := get_level_camera_shot(&level, "fixed_angle")
	testing.expect(t, ok, "a camera left at zero made no shot")

	// A zero would be 70 by the time it was rendered and 0 to anything that
	// read the shot back -- a game drawing its own frustum, or a test.
	testing.expect_value(t, shot.fov, CAMERA_DEFAULTS.fov)
}
