package level

/*
	Colliders, without a window and without a solver
	------------------------------------------------
	What a game reads off a collider: the world-space body it should make.
	Every expected value here is worked out by hand in the comment beside it,
	from the entity's transform and the collider's own size -- the point being
	that a physics engine is never needed to say whether this package got the
	arithmetic right.

	Whether the description actually builds the body meant is asserted where
	both packages are in scope, in Stargate's `editor/collision_test.odin`.
*/

import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:testing"

import mb "../matchbox"

@(private = "file")
near :: proc(a, b: [3]f32, tolerance: f32 = 1e-4) -> bool {
	return linalg.length(a - b) <= tolerance
}

@(private = "file")
collided :: proc(
	id: u64,
	name: string,
	position: [3]f32,
	collider: Collider_Component,
	scale := [3]f32{1, 1, 1},
	rotation := [4]f32{0, 0, 0, 1},
) -> Entity {
	return Entity{
		id        = id,
		name      = name,
		transform = {position = position, rotation = rotation, scale = scale},
		collider  = collider,
	}
}

@(private = "file")
level_with_colliders :: proc(entities: ..Entity) -> Level {
	level := create_level()
	for entity in entities do append(&level.entities, entity)
	update_level(&level)
	return level
}

/*
	A floor: a static box 20 by 0.5 by 20 in half-extents, at the origin, with
	its collider centred half a unit below where it is drawn so that its top
	face is y = 0.
*/
@(test)
test_a_box_collider_describes_the_body_to_make :: proc(t: ^testing.T) {
	level := level_with_colliders(collided(1, "floor", {0, 0, 0}, Collider_Component{
		kind     = .BOX,
		body     = .STATIC,
		size     = {20, 0.5, 20},
		offset   = {0, -0.5, 0},
		density  = 1,
		friction = 0.6,
	}))
	defer destroy_level(&level)

	desc, ok := collider_desc(&level, Entity_Handle{index = 0, id = 1})
	testing.expect(t, ok, "a collider should describe a body")

	testing.expect_value(t, desc.kind, Collider_Kind.BOX)
	testing.expect_value(t, desc.body, Collider_Body.STATIC)
	testing.expect_value(t, desc.name, "floor")
	testing.expect_value(t, desc.entity.id, u64(1))

	// Unscaled and unturned, the description is the component put in the world.
	testing.expect_value(t, desc.position, [3]f32{0, 0, 0})
	testing.expect_value(t, desc.offset, [3]f32{0, -0.5, 0})
	testing.expect_value(t, desc.center, [3]f32{0, -0.5, 0})
	testing.expect_value(t, desc.half_extents, [3]f32{20, 0.5, 20})
	testing.expect_value(t, desc.rotation, quaternion128(1))
	testing.expect_value(t, desc.friction, f32(0.6))

	// Read by name, the way a game reads one while setting up.
	named, found := get_level_collider(&level, "floor")
	testing.expect(t, found, "by name too")
	testing.expect_value(t, named.half_extents, desc.half_extents)

	_, missing := get_level_collider(&level, "no such entity")
	testing.expect(t, !missing, "a name that is not there answers false")

	// An entity with no collider is not a failure, it is simply not one.
	empty := create_level()
	defer destroy_level(&empty)
	append(&empty.entities, Entity{id = 1, name = "marker", transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}}})
	update_level(&empty)

	_, has := collider_desc(&empty, Entity_Handle{index = 0, id = 1})
	testing.expect(t, !has, "an entity with no collider describes no body")
	testing.expect_value(t, len(level_colliders(&empty, context.temp_allocator)), 0)
}

/*
	Scale reaches a collider, unlike a light or a camera: a wall scaled to twice
	the length is twice as long to walk along.

	A unit box (half-extents 0.5) at (2, 0, 0), scaled (4, 1, 0.25), with its
	centre a unit above the origin:

	- half-extents become (2, 0.5, 0.125)
	- the offset is scaled too, so the centre is 1 * 1 = 1 above: (2, 1, 0)
*/
@(test)
test_scale_reaches_the_collider :: proc(t: ^testing.T) {
	level := level_with_colliders(collided(1, "wall", {2, 0, 0}, Collider_Component{
		kind = .BOX, size = {0.5, 0.5, 0.5}, offset = {0, 1, 0}, density = 1, friction = 0.6,
	}, scale = {4, 1, 0.25}))
	defer destroy_level(&level)

	desc, _ := collider_desc(&level, Entity_Handle{index = 0, id = 1})

	testing.expect_value(t, desc.half_extents, [3]f32{2, 0.5, 0.125})
	testing.expect_value(t, desc.offset, [3]f32{0, 1, 0})
	testing.expect_value(t, desc.center, [3]f32{2, 1, 0})
}

/*
	A turned entity turns its collider, and turns the offset with it -- the
	whole reason `position` and `offset` are handed over separately rather than
	added up here.

	A quarter turn about Z takes +Y to -X. So a collider offset a unit straight
	up, on an entity at (5, 0, 0) turned a quarter about Z, has its centre at
	(4, 0, 0): one unit along -X.
*/
@(test)
test_a_turned_entity_turns_its_collider_and_its_offset :: proc(t: ^testing.T) {
	q := linalg.quaternion_angle_axis_f32(math.PI * 0.5, [3]f32{0, 0, 1})

	level := level_with_colliders(collided(1, "post", {5, 0, 0}, Collider_Component{
		kind = .BOX, size = {0.5, 1, 0.5}, offset = {0, 1, 0}, density = 1, friction = 0.6,
	}, rotation = {q.x, q.y, q.z, q.w}))
	defer destroy_level(&level)

	desc, _ := collider_desc(&level, Entity_Handle{index = 0, id = 1})

	// `position` is still where the entity is drawn; `offset` is still in the
	// entity's own space, unturned. Tether turns it.
	testing.expectf(t, near(desc.position, {5, 0, 0}), "position %v", desc.position)
	testing.expectf(t, near(desc.offset, {0, 1, 0}), "offset %v", desc.offset)

	testing.expectf(t, near(desc.center, {4, 0, 0}), "centre at %v, want {{4, 0, 0}}", desc.center)
	testing.expectf(t, abs(linalg.dot(desc.rotation, q)) > 0.9999, "rotation came back as %v", desc.rotation)

	// The half-extents are not turned: they are the box's own, and the rotation
	// is what turns the box.
	//
	// Near rather than exact, because the scale is recovered from the world
	// matrix by measuring its columns, and a turned matrix's columns are unit
	// length only to a float's accuracy -- a scale of 1 comes back as
	// 0.99999994. Everything that reads scale off a world matrix has this, and
	// it is a millionth of a unit on a collider.
	testing.expectf(t, near(desc.half_extents, {0.5, 1, 0.5}), "half-extents %v", desc.half_extents)
}

/*
	A collider under a parent: the world matrix is what is read, so a crate on a
	moved and turned table collides where it is drawn.

	The table is at (10, 0, 0) turned a quarter about Y, which takes +X to -Z.
	The crate sits at (2, 1, 0) in the table's space, so in the world it is at
	(10, 1, -2).
*/
@(test)
test_a_collider_under_a_parent_is_placed_in_the_world :: proc(t: ^testing.T) {
	q := linalg.quaternion_angle_axis_f32(math.PI * 0.5, [3]f32{0, 1, 0})

	level := create_level()
	defer destroy_level(&level)

	append(&level.entities, Entity{
		id = 1, name = "table",
		transform = {position = {10, 0, 0}, rotation = {q.x, q.y, q.z, q.w}, scale = {1, 1, 1}},
	})
	append(&level.entities, collided(2, "crate", {2, 1, 0}, Collider_Component{
		kind = .BOX, size = {0.5, 0.5, 0.5}, density = 1, friction = 0.6, body = .DYNAMIC,
	}))
	level.entities[1].parent = 1
	update_level(&level)

	desc, ok := collider_desc(&level, Entity_Handle{index = 1, id = 2})
	testing.expect(t, ok, "the crate has a collider")
	testing.expectf(t, near(desc.center, {10, 1, -2}), "crate centre at %v, want {{10, 1, -2}}", desc.center)
	testing.expect_value(t, desc.body, Collider_Body.DYNAMIC)

	// And by path through the tree, which is how a name repeated in several
	// groups is reached.
	by_path, found := get_level_collider(&level, "table/crate")
	testing.expect(t, found, "the crate is reachable by path")
	testing.expect_value(t, by_path.entity.id, u64(2))
}

/*
	A capsule cannot be an ellipse, so its radius takes the larger scale across
	its axis and its half-height the scale along it.

	Radius 0.35, half-height 0.5, on an entity scaled (2, 3, 1): the radius
	takes max(2, 1) = 2 and becomes 0.7; the half-height takes 3 and becomes
	1.5.
*/
@(test)
test_a_capsule_takes_the_larger_scale_across_its_axis :: proc(t: ^testing.T) {
	level := level_with_colliders(collided(1, "pillar", {0, 0, 0}, Collider_Component{
		kind = .CAPSULE, size = {0.35, 0.5, 0}, density = 1, friction = 0.6,
	}, scale = {2, 3, 1}))
	defer destroy_level(&level)

	desc, _ := collider_desc(&level, Entity_Handle{index = 0, id = 1})

	testing.expect_value(t, desc.kind, Collider_Kind.CAPSULE)
	testing.expect_value(t, desc.radius, f32(0.7))
	testing.expect_value(t, desc.half_height, f32(1.5))

	// The box fields are left at zero for a capsule, so a game switching on the
	// kind cannot use the wrong one by accident.
	testing.expect_value(t, desc.half_extents, [3]f32{0, 0, 0})
}

/*
	Every collider in the level, in list order, skipping the entities that have
	none.
*/
@(test)
test_level_colliders_lists_them_in_order :: proc(t: ^testing.T) {
	level := level_with_colliders(
		collided(1, "floor", {0, 0, 0}, Collider_Component{kind = .BOX, size = {10, 0.5, 10}, density = 1, friction = 0.6}),
		Entity{id = 2, name = "lamp", transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}}},
		collided(3, "crate", {0, 5, 0}, Collider_Component{kind = .BOX, body = .DYNAMIC, size = {0.5, 0.5, 0.5}, density = 1, friction = 0.6}),
	)
	defer destroy_level(&level)

	descs := level_colliders(&level, context.temp_allocator)

	testing.expect_value(t, len(descs), 2)
	testing.expect_value(t, descs[0].name, "floor")
	testing.expect_value(t, descs[1].name, "crate")

	// The handle in a desc names the entity it came from, index and all.
	testing.expect_value(t, descs[1].entity.index, 2)
	testing.expect_value(t, descs[1].entity.id, u64(3))
}

/*
	Fitting a collider to a model's own bounds, which is the one thing an editor
	cannot work out from the transform.

	A model whose bounds run (-1, 0, -0.5) to (1, 4, 0.5): 2 by 4 by 1, centred
	at (0, 2, 0).

	- a box gets half-extents (1, 2, 0.5) and that centre as its offset
	- a capsule's radius is the larger half-width, max(2, 1) * 0.5 = 1, and its
	  half-height is what is left over the rounded ends: 4 * 0.5 - 1 = 1
*/
@(test)
test_a_collider_is_fitted_to_its_model :: proc(t: ^testing.T) {
	model := model_with_bounds({-1, 0, -0.5}, {1, 4, 0.5})

	level := create_level()
	defer destroy_level(&level)

	append(&level.entities, Entity{
		id = 1, name = "pillar",
		transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		model     = Model_Component{path = "primitive:cube", tint = {1, 1, 1, 1}, model = &model},
		collider  = Collider_Component{kind = .BOX, density = 1, friction = 0.6},
	})
	update_level(&level)

	handle := Entity_Handle{index = 0, id = 1}

	testing.expect(t, fit_collider_to_model(&level, handle), "a box should fit")
	fitted, _ := level.entities[0].collider.?
	testing.expect_value(t, fitted.size, [3]f32{1, 2, 0.5})
	testing.expect_value(t, fitted.offset, [3]f32{0, 2, 0})

	if c, is_there := &level.entities[0].collider.?; is_there do c.kind = .CAPSULE
	testing.expect(t, fit_collider_to_model(&level, handle), "and a capsule")
	fitted, _ = level.entities[0].collider.?
	testing.expect_value(t, fitted.size.x, f32(1))
	testing.expect_value(t, fitted.size.y, f32(1))

	// A model shorter than it is wide leaves nothing over the rounded ends: a
	// sphere, not a capsule with a negative middle.
	squat := model_with_bounds({-2, 0, -2}, {2, 1, 2})
	if m, is_there := &level.entities[0].model.?; is_there do m.model = &squat
	testing.expect(t, fit_collider_to_model(&level, handle))
	fitted, _ = level.entities[0].collider.?
	testing.expect_value(t, fitted.size.x, f32(2))
	testing.expect_value(t, fitted.size.y, f32(0))

	// Nothing to fit to: an entity with no model, and one whose model failed to
	// load, both answer false rather than sizing the collider to nothing.
	if m, is_there := &level.entities[0].model.?; is_there do m.model = nil
	testing.expect(t, !fit_collider_to_model(&level, handle), "a model that did not load cannot be fitted to")

	level.entities[0].model = nil
	testing.expect(t, !fit_collider_to_model(&level, handle), "nor can no model at all")
}

/*
	A hand-written file that leaves keys out: every zero that has no sensible
	meaning gets its default, and the ones that do are kept.
*/
@(test)
test_a_collider_written_by_hand_gets_its_defaults :: proc(t: ^testing.T) {
	text := `{
		"version": 1,
		"entities": [
			{
				"id": 1,
				"name": "floor",
				"transform": {"position": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
				"collider": {"kind": "BOX", "body": "STATIC"}
			},
			{
				"id": 2,
				"name": "ball",
				"transform": {"position": [0, 4, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
				"collider": {"kind": "CAPSULE", "body": "DYNAMIC", "size": [0.5, 0, 0], "friction": 0.001}
			}
		]
	}`

	level, problems, err := unmarshal_level(transmute([]byte)text)
	defer destroy_level(&level)
	defer delete_problems(problems)

	testing.expect_value(t, err, nil)

	floor, _ := level.entities[0].collider.?
	testing.expect_value(t, floor.size, [3]f32{0.5, 0.5, 0.5})
	testing.expect_value(t, floor.density, f32(1))
	testing.expect_value(t, floor.friction, f32(0.6))

	// A capsule's zero half-height is a sphere and is left alone; its radius is
	// the one that must not be zero. A friction that was actually written is
	// kept whatever it is, which is how something near-frictionless is said.
	ball, _ := level.entities[1].collider.?
	testing.expect_value(t, ball.size.x, f32(0.5))
	testing.expect_value(t, ball.size.y, f32(0))
	testing.expect_value(t, ball.friction, f32(0.001))

	// A kind this build does not have is reported rather than read as BOX in
	// silence -- the same rule every other enum in the format follows.
	bad := `{"version": 1, "entities": [{"id": 1, "name": "x",
		"transform": {"position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1]},
		"collider": {"kind": "TRIMESH"}}]}`

	odd, odd_problems, _ := unmarshal_level(transmute([]byte)bad)
	defer destroy_level(&odd)
	defer delete_problems(odd_problems)

	testing.expect_value(t, len(odd_problems), 1)
}

/*
	A level with colliders survives the file, and a level written before
	colliders existed still loads -- the two rules a new optional component has
	to keep (plan section 4).
*/
@(test)
test_a_collider_survives_the_file_and_an_older_level_still_loads :: proc(t: ^testing.T) {
	built := create_level()
	append(&built.entities, collided(1, "floor", {0, -0.5, 0}, Collider_Component{
		kind = .BOX, body = .STATIC, size = {20, 0.5, 20}, density = 1, friction = 0.6,
	}))
	append(&built.entities, collided(2, "barrel", {0, 3, 0}, Collider_Component{
		kind = .CAPSULE, body = .DYNAMIC, size = {0.4, 0.3, 0}, offset = {0, 0.7, 0}, density = 2, friction = 0.4,
	}))

	first, err := marshal_level(built)
	testing.expect_value(t, err, nil)
	defer delete(first)
	destroy_level(&built)

	read, problems, unmarshal_err := unmarshal_level(first)
	defer destroy_level(&read)
	defer delete_problems(problems)

	testing.expect_value(t, unmarshal_err, nil)
	testing.expect_value(t, len(problems), 0)

	barrel, has := read.entities[1].collider.?
	testing.expect(t, has, "the capsule came back")
	testing.expect_value(t, barrel.kind, Collider_Kind.CAPSULE)
	testing.expect_value(t, barrel.body, Collider_Body.DYNAMIC)
	testing.expect_value(t, barrel.size, [3]f32{0.4, 0.3, 0})
	testing.expect_value(t, barrel.offset, [3]f32{0, 0.7, 0})
	testing.expect_value(t, barrel.density, f32(2))

	again, again_err := marshal_level(read)
	testing.expect_value(t, again_err, nil)
	defer delete(again)
	testing.expect_value(t, string(again), string(first))

	// A level from before colliders existed: no `collider` key at all.
	older := `{"version": 1, "entities": [{"id": 1, "name": "crate",
		"transform": {"position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1]}}]}`

	old, old_problems, old_err := unmarshal_level(transmute([]byte)older)
	defer destroy_level(&old)
	defer delete_problems(old_problems)

	testing.expect_value(t, old_err, nil)
	_, any_collider := old.entities[0].collider.?
	testing.expect(t, !any_collider, "no key means no collider, not an empty one")
}

/*
	The names this package writes into a file, asserted rather than assumed:
	they are what a hand-written level and a game's own switch both spell, so a
	rename here is a rename everywhere.
*/
@(test)
test_the_collider_enums_are_written_by_name :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)
	append(&level.entities, collided(1, "wall", {0, 0, 0}, Collider_Component{
		kind = .CAPSULE, body = .KINEMATIC, size = {1, 1, 1}, density = 1, friction = 0.6,
	}))

	data, err := marshal_level(level)
	testing.expect_value(t, err, nil)
	defer delete(data)

	text := string(data)
	testing.expect(t, strings.contains(text, `"kind": "CAPSULE"`), "the kind is written by name")
	testing.expect(t, strings.contains(text, `"body": "KINEMATIC"`), "and so is the body type")

	// And the whole component is absent from an entity without one, rather than
	// written as a block of zeros.
	plain := create_level()
	defer destroy_level(&plain)
	append(&plain.entities, Entity{id = 1, name = "empty", transform = {rotation = {0, 0, 0, 1}, scale = {1, 1, 1}}})

	plain_data, _ := marshal_level(plain)
	defer delete(plain_data)
	testing.expect(t, strings.contains(string(plain_data), `"collider": null`), "an entity with none writes null")
}

// A model with nothing in it but bounds, which is all `fit_collider_to_model`
// reads. Built by hand rather than loaded: no GPU, no file.
@(private = "file")
model_with_bounds :: proc(low, high: [3]f32) -> mb.Model {
	return mb.Model{bounds_min = low, bounds_max = high}
}
