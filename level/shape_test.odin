package level

/*
	Shapes, without a window
	-------------------------
	What a game reads off a shape: the corners a fixed camera shot wants, and
	whether a point is inside. Expected values are worked out by hand in the
	comments beside them, from the right-hand rule and the definition of a
	rotation about Y.
*/

import "core:math"
import "core:testing"

@(private = "file")
level_with :: proc(entities: ..Entity) -> Level {
	level := create_level()
	for entity in entities do append(&level.entities, entity)
	update_level(&level)
	return level
}

@(private = "file")
shaped :: proc(id: u64, name: string, position: [3]f32, shape: Shape_Component, scale := [3]f32{1, 1, 1}, rotation := [4]f32{0, 0, 0, 1}) -> Entity {
	return Entity{
		id        = id,
		name      = name,
		transform = {position = position, rotation = rotation, scale = scale},
		shape     = shape,
	}
}

@(test)
test_a_box_answers_with_its_corners :: proc(t: ^testing.T) {
	// At (10, 0, 0), scaled 2, half-extents (1, 0.5, 1): the box reaches 2, 1
	// and 2 from its middle.
	level := level_with(shaped(1, "hall", {10, 0, 0}, {kind = .BOX, size = {1, 0.5, 1}}, scale = {2, 2, 2}))
	defer destroy_level(&level)

    handle := Entity_Handle{index = 0, id = 1}
	low, high, ok := shape_bounds(&level, handle)

	testing.expect(t, ok, "a box should answer")
	testing.expect_value(t, low, [3]f32{8, -1, -2})
	testing.expect_value(t, high, [3]f32{12, 1, 2})

	// By name, the way a game reads it while setting a camera shot up.
	named_low, named_high, found := get_level_shape_bounds(&level, "hall")
	testing.expect(t, found, "by name too")
	testing.expect_value(t, named_low, low)
	testing.expect_value(t, named_high, high)

	_, _, missing := get_level_shape_bounds(&level, "no such entity")
	testing.expect(t, !missing, "a name that is not there answers false")
}

// A unit box turned 45 degrees about Y: its corners reach sqrt(2) along x and
// z, and the turn does not touch y.
@(test)
test_a_turned_box_answers_with_the_box_around_it :: proc(t: ^testing.T) {
	turn := [4]f32{0, math.sin(f32(math.PI / 8)), 0, math.cos(f32(math.PI / 8))} // 45 degrees about Y
	level := level_with(shaped(1, "zone", {0, 0, 0}, {kind = .BOX, size = {1, 1, 1}}, rotation = turn))
	defer destroy_level(&level)

	low, high, ok := shape_bounds(&level, Entity_Handle{index = 0, id = 1})
	testing.expect(t, ok, "a turned box should answer")

	root_two := math.sqrt_f32(2)
	testing.expect(t, abs(high.x - root_two) < 1e-4 && abs(high.z - root_two) < 1e-4,
		"the corners should reach sqrt(2) along x and z")
	testing.expect(t, abs(high.y - 1) < 1e-4, "and 1 along y, which the turn does not touch")
	testing.expect(t, abs(low.x + root_two) < 1e-4, "and the same the other way")
}

/*
	The exact test, which the corners cannot give. A box of half-extents
	(2, 1, 0.5) turned 45 degrees about Y:

	- (0.7071, 0, -0.7071) is local (1, 0, 0): inside, along the long axis
	- (0.6, 0, 0.6) is local (0, 0, 0.8485): outside, past the 0.5 face --
	  though it is well inside the upright box around the shape
*/
@(test)
test_a_point_inside_a_turned_box :: proc(t: ^testing.T) {
	turn := [4]f32{0, math.sin(f32(math.PI / 8)), 0, math.cos(f32(math.PI / 8))}
	level := level_with(shaped(1, "trigger", {0, 0, 0}, {kind = .BOX, size = {2, 1, 0.5}}, rotation = turn))
	defer destroy_level(&level)

	handle := Entity_Handle{index = 0, id = 1}
	testing.expect(t, shape_contains(&level, handle, {0.7071, 0, -0.7071}), "along the long axis, inside")
	testing.expect(t, !shape_contains(&level, handle, {0.6, 0, 0.6}), "past the near face, outside")

	// And that second point really is inside the corners, which is why the
	// exact test is worth having.
	low, high, _ := shape_bounds(&level, handle)
	inside_bounds := low.x <= 0.6 && 0.6 <= high.x && low.z <= 0.6 && 0.6 <= high.z
	testing.expect(t, inside_bounds, "the upright box around it does contain that point")
}

// A sphere has one radius, so under a parent scaled 3 it grows by 3.
@(test)
test_a_sphere_grows_with_its_scale :: proc(t: ^testing.T) {
	level := level_with(
		Entity{id = 1, name = "big", transform = {position = {0, 2, 0}, rotation = {0, 0, 0, 1}, scale = {3, 3, 3}}},
		shaped(2, "bubble", {0, 0, 0}, {kind = .SPHERE, size = {0.5, 0, 0}}),
	)
	defer destroy_level(&level)

	level.entities[1].parent = 1
	update_level(&level)

	handle := Entity_Handle{index = 1, id = 2}
	low, high, ok := shape_bounds(&level, handle)
	testing.expect(t, ok, "a sphere should answer")
	testing.expect_value(t, low, [3]f32{-1.5, 0.5, -1.5})
	testing.expect_value(t, high, [3]f32{1.5, 3.5, 1.5})

	testing.expect(t, shape_contains(&level, handle, {1.4, 2, 0}), "inside the grown radius")
	testing.expect(t, !shape_contains(&level, handle, {1.6, 2, 0}), "outside it")

	// A point shape has no inside, and no size.
	point := level_with(shaped(1, "spawn", {1, 2, 3}, {kind = .POINT}))
	defer destroy_level(&point)
	low, high, _ = shape_bounds(&point, Entity_Handle{index = 0, id = 1})
	testing.expect_value(t, low, [3]f32{1, 2, 3})
	testing.expect_value(t, high, [3]f32{1, 2, 3})
	testing.expect(t, !shape_contains(&point, Entity_Handle{index = 0, id = 1}, {1, 2, 3}), "a point has no inside")
}

// An entity with no shape answers false rather than zero.
@(test)
test_an_entity_without_a_shape_answers_false :: proc(t: ^testing.T) {
	level := level_with(Entity{id = 1, name = "crate", transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}}})
	defer destroy_level(&level)

	_, _, ok := shape_bounds(&level, Entity_Handle{index = 0, id = 1})
	testing.expect(t, !ok, "no shape, no bounds")
	testing.expect(t, !shape_contains(&level, Entity_Handle{index = 0, id = 1}, {0, 0, 0}), "and nothing is inside it")
}

/*
	A shape goes through the file and comes back the same, and a level written
	before shapes existed still loads -- the two rules section 4 of Stargate's
	plan relies on: an unknown key is skipped, and a missing one is the zero
	value.
*/
@(test)
test_a_shape_survives_the_file_and_an_older_level_still_loads :: proc(t: ^testing.T) {
	level := level_with(
		shaped(1, "hall", {4, 1, -2}, {kind = .BOX, size = {3, 2, 1}, color = {0.2, 0.9, 0.4, 1}}),
		shaped(2, "bubble", {0, 0, 0}, {kind = .SPHERE, size = {1.5, 0, 0}, color = {1, 0.5, 0, 1}}),
	)
	defer destroy_level(&level)

	first, marshal_err := marshal_level(level, allocator = context.temp_allocator)
	testing.expectf(t, marshal_err == nil, "marshal: %v", marshal_err)

	read, problems, err := unmarshal_level(first, context.temp_allocator)
	defer delete_problems(problems)
	testing.expectf(t, err == nil, "unmarshal: %v", err)
	testing.expectf(t, len(problems) == 0, "a level with shapes should read cleanly: %v", problems)

	shape, has_shape := read.entities[0].shape.?
	testing.expect(t, has_shape, "the box should come back")
	testing.expect_value(t, shape.kind, Shape_Kind.BOX)
	testing.expect_value(t, shape.size, [3]f32{3, 2, 1})
	testing.expect_value(t, shape.color, [4]f32{0.2, 0.9, 0.4, 1})

	again, _ := marshal_level(read, allocator = context.temp_allocator)
	testing.expect(t, string(first) == string(again), "a level with shapes saves to the same bytes twice")

	// A level from before shapes: no `shape` key at all.
	older := `{
		"version": 1,
		"settings": {"background": [0, 0, 0, 1], "lighting": {"enabled": true, "exposure": 1}},
		"entities": [
			{"id": 1, "name": "crate", "parent": 0,
			 "transform": {"position": [1, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
			 "model": null, "light": null}
		]
	}`

	old_level, old_problems, old_err := unmarshal_level(transmute([]byte)older, context.temp_allocator)
	defer delete_problems(old_problems)
	testing.expectf(t, old_err == nil, "a level from before shapes should load: %v", old_err)
	testing.expectf(t, len(old_problems) == 0, "and report nothing: %v", old_problems)

	_, had_shape := old_level.entities[0].shape.?
	testing.expect(t, !had_shape, "and have no shape")
}

// A shape with nothing filled in gets the defaults, the way a light does.
@(test)
test_a_shape_with_no_size_gets_the_defaults :: proc(t: ^testing.T) {
	bare := `{
		"version": 1,
		"settings": {"background": [0, 0, 0, 1], "lighting": {"enabled": true, "exposure": 1}},
		"entities": [
			{"id": 1, "name": "zone", "parent": 0,
			 "transform": {"position": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
			 "shape": {"kind": "BOX", "size": [0, 0, 0], "color": [0, 0, 0, 0]}},
			{"id": 2, "name": "ball", "parent": 0,
			 "transform": {"position": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
			 "shape": {"kind": "SPHERE", "size": [0, 0, 0], "color": [0, 0, 0, 0]}}
		]
	}`

	level, problems, err := unmarshal_level(transmute([]byte)bare, context.temp_allocator)
	defer delete_problems(problems)
	testing.expectf(t, err == nil, "it should load: %v", err)

	box := level.entities[0].shape.? or_else Shape_Component{}
	testing.expect_value(t, box.size, [3]f32{SHAPE_DEFAULTS.size, SHAPE_DEFAULTS.size, SHAPE_DEFAULTS.size})
	testing.expect_value(t, box.color, SHAPE_DEFAULTS.color)

	ball := level.entities[1].shape.? or_else Shape_Component{}
	testing.expect_value(t, ball.size.x, SHAPE_DEFAULTS.size)
	testing.expect_value(t, shape_color(ball), SHAPE_DEFAULTS.color)
}
