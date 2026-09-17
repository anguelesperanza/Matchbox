package level

/*
	World transforms and lights
	---------------------------
	Every expected value below was worked out by hand from the right-hand rule
	-- turning +90 degrees about +Y takes +X to -Z and -Z to -X; about +X takes
	-Z to +Y -- and not by running this code and writing down what it said.
	Turning by an angle uses Matchbox's `transform_rotation`; everything after
	that is what is being checked.

	Nothing here opens a window or touches a GPU.
*/

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"

import mb ".."

@(private)
turned :: proc(axis: [3]f32, degrees: f32) -> [4]f32 {
	q := mb.transform_rotation(axis, math.to_radians(degrees))
	return {q.x, q.y, q.z, q.w}
}

@(private)
add_test_entity :: proc(
	level: ^Level,
	id, parent: u64,
	position: [3]f32,
	rotation: [4]f32 = {0, 0, 0, 1},
	scale: [3]f32 = {1, 1, 1},
) -> Entity_Handle {
	append(&level.entities, Entity{
		id        = id,
		parent    = parent,
		name      = strings.clone(fmt.tprintf("entity %d", id)),
		transform = {position = position, rotation = rotation, scale = scale},
	})
	return {index = len(level.entities) - 1, id = id}
}

@(private)
expect_near :: proc(t: ^testing.T, got, want: [3]f32, what: string, loc := #caller_location) {
	testing.expectf(t, linalg.length(got - want) < 1e-4, "%s: got %v, want %v", what, got, want, loc = loc)
}

@(private)
rotate :: proc(q: quaternion128, v: [3]f32) -> [3]f32 {
	return linalg.quaternion_mul_vector3(q, v)
}

@(test)
test_world_through_a_three_deep_chain_listed_children_first :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	// Listed grandchild, child, parent -- the reverse of the order a
	// parents-first loop would need.
	c := add_test_entity(&level, 3, 2, {0, 1, 0}, turned({1, 0, 0}, 90))
	b := add_test_entity(&level, 2, 1, {0, 0, -2}, scale = {2, 2, 2})
	a := add_test_entity(&level, 1, 0, {1, 0, 0}, turned({0, 1, 0}, 90))

	update_level(&level)

	at, _ := get_world_transform(&level, a)
	expect_near(t, at.position, {1, 0, 0}, "a position")

	// (1, 0, 0) + Ry(90) * (0, 0, -2) = (1, 0, 0) + (-2, 0, 0)
	bt, _ := get_world_transform(&level, b)
	expect_near(t, bt.position, {-1, 0, 0}, "b position")
	expect_near(t, bt.scale, {2, 2, 2}, "b scale")

	// (-1, 0, 0) + Ry(90) * (2 * (0, 1, 0)) = (-1, 2, 0); turned X90 inside Y90,
	// so -Z goes to +Y and stays there, and +X goes to -Z.
	ct, _ := get_world_transform(&level, c)
	expect_near(t, ct.position, {-1, 2, 0}, "c position")
	expect_near(t, ct.scale, {2, 2, 2}, "c scale")
	expect_near(t, rotate(ct.rotation, {0, 0, -1}), {0, 1, 0}, "c forward")
	expect_near(t, rotate(ct.rotation, {1, 0, 0}), {0, 0, -1}, "c right")
}

@(test)
test_set_world_transform_round_trips_under_a_turned_scaled_parent :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	add_test_entity(&level, 1, 0, {3, 1, -2}, turned({0, 1, 0}, 90), {2, 2, 2})
	child := add_test_entity(&level, 2, 1, {0, 0, 0})
	update_level(&level)

	want := mb.Transform{
		position = {5, 5, 5},
		rotation = mb.transform_rotation({1, 0, 0}, math.to_radians(f32(30))),
		scale    = {1, 1, 1},
	}
	if !testing.expect(t, set_world_transform(&level, child, want), "set_world_transform refused") do return

	// What was stored is relative to the parent: Ry(-90) takes (x, y, z) to
	// (-z, y, x), so ((5, 5, 5) - (3, 1, -2)) / 2 = (1, 2, 3.5) becomes
	// (-3.5, 2, 1), at half the scale.
	stored := get_entity(&level, child).transform
	expect_near(t, stored.position, {-3.5, 2, 1}, "stored local position")
	expect_near(t, stored.scale, {0.5, 0.5, 0.5}, "stored local scale")

	for pass in ([]string{"straight after setting", "after update_level"}) {
		got, _ := get_world_transform(&level, child)
		expect_near(t, got.position, want.position, fmt.tprintf("%s: position", pass))
		expect_near(t, got.scale, want.scale, fmt.tprintf("%s: scale", pass))
		expect_near(t, rotate(got.rotation, {0, 0, -1}), rotate(want.rotation, {0, 0, -1}), fmt.tprintf("%s: forward", pass))
		expect_near(t, rotate(got.rotation, {1, 0, 0}), rotate(want.rotation, {1, 0, 0}), fmt.tprintf("%s: right", pass))
		update_level(&level)
	}
}

@(test)
test_set_world_transform_refuses_a_parent_scaled_to_zero :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	add_test_entity(&level, 1, 0, {0, 0, 0}, scale = {1, 0, 1})
	child := add_test_entity(&level, 2, 1, {4, 0, 0})
	update_level(&level)

	before := get_entity(&level, child).transform
	testing.expect(t, !set_world_transform(&level, child, mb.create_transform({9, 9, 9})), "a parent with no inverse was accepted")
	testing.expect(t, get_entity(&level, child).transform == before, "the refused call changed the transform")
}

@(test)
test_a_light_turned_about_each_axis :: proc(t: ^testing.T) {
	Case :: struct {
		axis:           [3]f32,
		forward, right: [3]f32,
	}

	cases := []Case{
		{axis = {1, 0, 0}, forward = {0, 1, 0},  right = {1, 0, 0}},
		{axis = {0, 1, 0}, forward = {-1, 0, 0}, right = {0, 0, -1}},
		{axis = {0, 0, 1}, forward = {0, 0, -1}, right = {0, 1, 0}},
	}

	for c in cases {
		level := create_level()
		defer destroy_level(&level)

		h := add_test_entity(&level, 1, 0, {1, 2, 3}, turned(c.axis, 90))
		entity := get_entity(&level, h)
		update_level(&level)

		what := fmt.tprintf("turned about %v", c.axis)

		entity.light = Light_Component{kind = .SPOT, color = {1, 0.5, 0.25, 1}, intensity = 2, inner_angle = 10, outer_angle = 25, casts_shadow = true}
		spot, ok := light_from_entity(entity^)
		if !testing.expect(t, ok, "no light from a light component") do continue
		expect_near(t, spot.position, {1, 2, 3}, fmt.tprintf("%s: spot position", what))
		expect_near(t, spot.target, c.forward, fmt.tprintf("%s: spot direction", what))
		testing.expect_value(t, spot.kind, mb.Light_Kind.SPOT)
		testing.expect_value(t, spot.color, [4]f32{2, 1, 0.5, 1})
		testing.expect_value(t, spot.inner_angle, 10)
		testing.expect_value(t, spot.outer_angle, 25)
		testing.expect_value(t, spot.casts_shadow, true)

		// A directional light keeps its direction in `target` too, from nowhere.
		entity.light = Light_Component{kind = .DIRECTIONAL, color = mb.WHITE, intensity = 1}
		sun, _ := light_from_entity(entity^)
		expect_near(t, sun.target, c.forward, fmt.tprintf("%s: directional direction", what))

		// An area light faces along -Z and is wide along +X; the component's
		// half-extents come back as half-extents.
		entity.light = Light_Component{kind = .AREA_RECT, color = mb.WHITE, intensity = 1, area_size = {1, 0.5}}
		panel, _ := light_from_entity(entity^)
		expect_near(t, panel.target, c.forward, fmt.tprintf("%s: area normal", what))
		expect_near(t, panel.area_right, c.right, fmt.tprintf("%s: area width axis", what))
		testing.expect_value(t, panel.area_size, [2]f32{1, 0.5})
	}
}

@(test)
test_a_light_under_a_turned_moved_scaled_parent :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	add_test_entity(&level, 1, 0, {10, 0, 0}, turned({0, 1, 0}, 90), {3, 3, 3})
	lamp := add_test_entity(&level, 2, 1, {0, 0, -2})
	get_entity(&level, lamp).light = Light_Component{kind = .SPOT, color = mb.WHITE, intensity = 1}
	update_level(&level)

	lights := level_lights(&level)
	defer delete(lights)
	if !testing.expect_value(t, len(lights), 1) do return

	// (10, 0, 0) + Ry(90) * (3 * (0, 0, -2)) = (10, 0, 0) + (-6, 0, 0). The
	// parent's scale moves the lamp but does not stretch its direction.
	expect_near(t, lights[0].position, {4, 0, 0}, "position")
	expect_near(t, lights[0].target, {-1, 0, 0}, "direction")
	testing.expectf(t, math.abs(linalg.length(lights[0].target) - 1) < 1e-4, "direction is not unit length: %v", lights[0].target)
}

@(test)
test_handles_follow_their_entity_and_notice_it_is_gone :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	add_test_entity(&level, 1, 0, {0, 0, 0})
	add_test_entity(&level, 2, 0, {0, 0, 0})
	add_test_entity(&level, 3, 0, {7, 0, 0})

	spawn, found := find_entity(&level, "entity 3")
	if !testing.expect(t, found, "find_entity missed a name that is there") do return
	testing.expect_value(t, spawn.index, 2)

	// Removing an entity before it moves it down a slot; the handle's index is
	// stale and its id still finds it.
	removed := level.entities[0]
	ordered_remove(&level.entities, 0)
	delete(removed.name)

	entity := get_entity(&level, spawn)
	if testing.expect(t, entity != nil, "a moved entity was reported gone") {
		testing.expect_value(t, entity.id, 3)
	}

	// Removing the entity itself: its handle names nothing now.
	gone := level.entities[1]
	ordered_remove(&level.entities, 1)
	delete(gone.name)
	testing.expect(t, get_entity(&level, spawn) == nil, "a removed entity's handle still names something")
}

/*
	Two groups whose children have the same names as each other -- what the
	editor makes the moment a shot is duplicated, and what `find_entity` alone
	cannot get past.

		cameras
		  fixed_angle_one   camera  bounds
		  fixed_angle_two   camera  bounds
*/
@(private = "file")
two_shot_groups :: proc(level: ^Level) {
	named :: proc(level: ^Level, id, parent: u64, name: string, position: [3]f32) {
		append(&level.entities, Entity{
			id        = id,
			parent    = parent,
			name      = strings.clone(name, level_allocator(level)),
			transform = {position = position, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		})
	}

	named(level, 1, 0, "cameras",         {0, 0, 0})
	named(level, 2, 1, "fixed_angle_one", {10, 0, 0})
	named(level, 3, 2, "camera",          {0, 2, 0})
	named(level, 4, 2, "bounds",          {0, 0, 5})
	named(level, 5, 1, "fixed_angle_two", {-10, 0, 0})
	named(level, 6, 5, "camera",          {0, 3, 0})
	named(level, 7, 5, "bounds",          {0, 0, -5})
}

@(test)
test_a_path_reaches_the_child_that_shares_its_name_with_another :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	two_shot_groups(&level)
	update_level(&level)

	// The premise: by name alone, both lookups answer the same entity, which is
	// the bug this is here to fix rather than a quirk of the fixture.
	first, found := find_entity(&level, "camera")
	testing.expect(t, found, "find_entity missed a name that is there")
	testing.expect_value(t, first.id, 3)

	one, ok_one := find_entity_path(&level, "fixed_angle_one/camera")
	two, ok_two := find_entity_path(&level, "fixed_angle_two/camera")
	testing.expect(t, ok_one && ok_two, "a path missed a child that is there")
	testing.expect_value(t, one.id, 3)
	testing.expect_value(t, two.id, 6)

	// And the whole way down from the root of the group.
	deep, ok_deep := find_entity_path(&level, "cameras/fixed_angle_two/bounds")
	testing.expect(t, ok_deep, "a three-name path missed")
	testing.expect_value(t, deep.id, 7)

	// The world transform is the group's plus the child's, so a path is worth
	// having only if it answers the right one: -10 + 0, not 10 + 0.
	expect_near(t, get_level_entity_transform(&level, "fixed_angle_two/camera"), {-10, 3, 0},
		"a path read the wrong group's camera")
}

@(test)
test_a_path_that_names_nothing_is_not_found :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	two_shot_groups(&level)
	update_level(&level)

	for path in ([]string{
		"",                              // nothing at all
		"fixed_angle_one/",              // a trailing separator
		"/fixed_angle_one",              // a leading one
		"cameras//fixed_angle_one",      // a doubled one
		"fixed_angle_one/lens",          // a child that is not there
		"fixed_angle_one/camera/bounds", // a grandchild of a leaf
		"bounds/camera",                 // the right names, the wrong way round
		"cameras/camera",                // a grandchild named as a child
	}) {
		_, found := find_entity_path(&level, path)
		testing.expectf(t, !found, "%q was found and should not have been", path)
	}
}

@(test)
test_children_are_the_direct_ones_in_list_order :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	two_shot_groups(&level)
	update_level(&level)

	group, _ := find_entity(&level, "cameras")

	children := level_children(&level, group, context.temp_allocator)
	defer delete(children, context.temp_allocator)

	// The two groups and not their four children: one level down, so a shot
	// gaining a part cannot turn into another shot here.
	testing.expect_value(t, len(children), 2)
	testing.expect_value(t, children[0].id, 2)
	testing.expect_value(t, children[1].id, 5)

	// A handle whose entity has gone answers nothing rather than answering the
	// roots, which is what an id of 0 would have matched.
	gone := level_children(&level, Entity_Handle{index = 99, id = 404}, context.temp_allocator)
	testing.expect(t, gone == nil, "a dead handle listed children")
}
