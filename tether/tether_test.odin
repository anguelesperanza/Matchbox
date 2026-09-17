package tether

/*
	Run these single-threaded:

		odin test tether -define:ODIN_TEST_THREADS=1

	Every test makes and destroys the one world in `tpi`, and the test runner
	otherwise runs tests side by side against that same global.

	Each one drives the two games' own patterns and asserts on the numbers the
	solver hands back, rather than on anything drawn.
*/

import "core:math"
import "core:math/linalg"
import "core:testing"

import b3 "vendor:box3d"

@(private = "file")
Test_Category :: enum {
	WORLD  = 0,
	PLAYER = 1,
}

@(private = "file")
Test_Categories :: bit_set[Test_Category; u64]

@(private = "file")
UPRIGHT :: Motion_Locks{.LINEAR_Y, .ANGULAR_X, .ANGULAR_Y, .ANGULAR_Z}

@(private = "file")
near :: proc(a, b: [3]f32, tolerance: f32 = 0.01) -> bool {
	return linalg.length(a - b) <= tolerance
}

@(private = "file")
run_for :: proc(seconds: f32) {
	for _ in 0 ..< int(seconds * 60) do step()
}

@(test)
dropped_box_comes_to_rest_on_the_floor :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	// The floor both games build: a static slab whose top face is y = 0.
	create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})
	crate := create_box_body(position = {0, 3, 0}, half_extents = {0.2, 0.2, 0.2}, type = .DYNAMIC)

	run_for(3)

	position := get_body_position(&crate)
	testing.expectf(t, near(position, {0, 0.2, 0}, 0.02), "crate resting at %v, want {{0, 0.2, 0}}", position)
}

@(test)
origin_backs_the_offset_out_after_turning_it :: proc(t: ^testing.T) {
	init(gravity = {0, 0, 0})
	defer shutdown()

	// A model whose origin sits at its base, so the collider centre is 0.5 above it.
	item := create_box_body(position = {1, 0, 0}, offset = {0, 0.5, 0}, type = .DYNAMIC)

	testing.expectf(t, near(get_body_position(&item), {1, 0.5, 0}), "centre %v", get_body_position(&item))
	testing.expectf(t, near(get_body_origin(&item), {1, 0, 0}), "origin %v", get_body_origin(&item))

	// Tipped a quarter turn about +Z, the model's "up" now points along -X, so
	// its base is at the centre's +X. Worked out by hand, not with the same
	// quaternion maths `get_body_origin` uses, or the test would only agree with
	// itself.
	half := f32(math.SQRT_TWO * 0.5)
	quarter_turn := quaternion(w = half, x = 0, y = 0, z = half)
	set_body_transform(&item, {1, 0.5, 0}, quarter_turn)

	origin := get_body_origin(&item)
	testing.expectf(t, near(origin, {1.5, 0.5, 0}), "turned origin %v, want {{1.5, 0.5, 0}}", origin)
}

@(test)
ray_sees_only_its_mask_and_names_the_body :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	world  := category_bits(Test_Categories{.WORLD})
	player := category_bits(Test_Categories{.PLAYER})
	testing.expect_value(t, world, 1)
	testing.expect_value(t, player, 2)

	you  := create_capsule_body(position = {0, 1.7, 0}, radius = 0.4, type = .DYNAMIC, category = player, locks = UPRIGHT)
	wall := create_box_body(position = {0, 1, -5}, half_extents = {2, 1, 0.5}, category = world)

	// From behind the player, straight through them toward the wall. Starting
	// outside the capsule matters: a ray that starts strictly inside a shape does
	// not report it whatever the mask, so a ray from this capsule's centre would
	// pass this test without the mask doing anything.
	behind := [3]f32{0, 1.7, 3}

	unmasked := cast_ray(behind, {0, 0, -10})
	testing.expect(t, is_body_hit(unmasked, &you), "an unmasked ray should stop at the player in its way")

	hit := cast_ray(behind, {0, 0, -10}, mask = world)
	testing.expect(t, is_body_hit(hit, &wall), "a masked ray should pass the player and name the wall")
	testing.expect(t, !is_body_hit(hit, &you))
	testing.expect_value(t, hit.shape, wall.shape)
	testing.expectf(t, near(hit.point, {0, 1.7, -4.5}), "hit point %v", hit.point)
	testing.expectf(t, near(hit.normal, {0, 0, 1}), "hit normal %v", hit.normal)

	// From the capsule's centre with no mask at all: still the wall, never the
	// player. `cast_ray`'s comment rests on this and on the check below.
	from_centre := cast_ray({0, 1.7, 0}, {0, 0, -10})
	testing.expect(t, is_body_hit(from_centre, &wall), "a ray starting inside the capsule should not report it")

	// On and just above a capsule's top, looking down. Exactly on the surface is
	// ignored; one float step outside is reported; the mask leaves it out again.
	// `cast_ray`'s comment rests on all three. Sized so the top is exactly y = 2
	// -- centre 1, half_height 0.5, radius 0.5 -- so "on" really is on.
	standing := create_capsule_body(position = {5, 1, 0}, radius = 0.5, half_height = 0.5, category = player)
	just_above := transmute(f32)(transmute(u32)f32(2) + 1)

	on_top := cast_ray({5, 2, 0}, {0, -10, 0})
	testing.expect(t, !is_body_hit(on_top, &standing), "a ray starting exactly on the capsule's surface should not report it")

	above_top := cast_ray({5, just_above, 0}, {0, -10, 0})
	testing.expect(t, is_body_hit(above_top, &standing), "a ray starting one float step outside the capsule should report it")

	masked_above := cast_ray({5, just_above, 0}, {0, -10, 0}, mask = world)
	testing.expect(t, !is_body_hit(masked_above, &standing), "the mask should leave the capsule out")

	// Nothing along the other way.
	miss := cast_ray({0, 1.7, 0}, {0, 0, 10}, mask = world)
	testing.expect(t, !miss.hit)
	testing.expect_value(t, miss, Ray_Hit{})

	// The trap `is_body_hit` is for: a miss and a body never made share an id.
	never_made: Body
	testing.expect_value(t, miss.body, never_made.id)
	testing.expect(t, !is_body_hit(miss, &never_made), "a miss must not name a body that was never created")
}

@(test)
locked_player_walks_level_and_stays_upright :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})

	// Clear of the floor, so the Y lock is the only thing holding it up.
	you := create_capsule_body(position = {0, 1.7, 0}, radius = 0.4, type = .DYNAMIC, locks = UPRIGHT)

	// A second walking along +X at 2 units a second, velocity set every frame
	// the way both games move their player. Unlocked, it would have fallen 5.
	for _ in 0 ..< 60 {
		set_body_linear_velocity(&you, {2, 0, 0})
		step()
	}

	position := get_body_position(&you)
	testing.expectf(t, near(position, {2, 1.7, 0}, 0.02), "player at %v, want {{2, 1.7, 0}}", position)

	rotation := get_body_rotation(&you)
	testing.expectf(t, abs(rotation.w) > 0.9999, "player turned to %v", rotation)
}

@(test)
walls_stop_a_walking_player :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})
	create_box_body(position = {0, 1, -3}, half_extents = {3, 1, 0.5})
	you := create_capsule_body(position = {0, 1.7, 0}, radius = 0.4, type = .DYNAMIC, locks = UPRIGHT)

	// Three seconds at 3 units a second is nine units of asking, toward a wall
	// whose near face is 2.5 away.
	for _ in 0 ..< 180 {
		set_body_linear_velocity(&you, {0, 0, -3})
		step()
	}

	// Stopped with the capsule's radius between its centre and the face.
	z := get_body_position(&you).z
	testing.expectf(t, abs(z - (-2.5 + 0.4)) < 0.05, "player stopped at z = %v, want about -2.1", z)
}

@(test)
held_body_stays_put_and_placed_body_sits_on_the_surface :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})
	create_box_body(position = {5, 1, 0}, half_extents = {1, 1, 1})
	plate := create_box_body(position = {0, 0.1, 0}, half_extents = {0.3, 0.1, 0.3}, type = .DYNAMIC)

	// `hold_body`'s comment tells a game porting CoffeeGame's rotation to swap
	// the arguments. Hold it to that.
	facing := linalg.quaternion_angle_axis_f32(0.7, {0, 1, 0})
	box3d  := b3.MakeQuatFromAxisAngle({0, 1, 0}, 0.7)
	testing.expectf(t, abs(linalg.dot(facing, box3d)) > 0.9999, "linalg %v vs box3d %v", facing, box3d)

	// Held for a second, re-held every frame as CoffeeGame does. A dynamic body
	// would have dropped five units out of the hand in that time.
	hand := [3]f32{1, 1.5, 1}
	for _ in 0 ..< 60 {
		hold_body(&plate, hand, facing)
		step()
	}
	testing.expectf(t, near(get_body_position(&plate), hand), "held plate at %v", get_body_position(&plate))
	testing.expect_value(t, b3.Body_GetType(plate.id), b3.BodyType.kinematicBody)

	// A miss puts nothing down and moves nothing.
	testing.expect(t, !place_body(&plate, Ray_Hit{}))
	testing.expect(t, near(get_body_position(&plate), hand))

	// Onto the side of the block, whose near face is x = 4: out along -X by the
	// plate's half-width, so its face touches rather than overlaps.
	side := cast_ray({0, 1, 0}, {10, 0, 0})
	testing.expect(t, place_body(&plate, side))
	testing.expectf(t, near(get_body_position(&plate), {3.7, 1, 0}), "on the side at %v", get_body_position(&plate))

	// Onto the floor, from above: resting half its height up, square, dynamic,
	// and still there a second later.
	down := cast_ray({2, 3, 0}, {0, -10, 0})
	testing.expect(t, place_body(&plate, down))
	testing.expectf(t, near(get_body_position(&plate), {2, 0.1, 0}), "on the floor at %v", get_body_position(&plate))
	testing.expect_value(t, get_body_rotation(&plate), quaternion128(1))
	testing.expect_value(t, b3.Body_GetType(plate.id), b3.BodyType.dynamicBody)

	run_for(1)
	testing.expectf(t, near(get_body_position(&plate), {2, 0.1, 0}, 0.02), "settled at %v", get_body_position(&plate))
}

/*
	A turned body, which a level built in an editor has and neither game did.

	A ramp: a thin slab, wide in X and Z, tipped a quarter turn about Z so its
	face stands upright along X. A crate dropped where the flat slab would have
	been misses the turned one entirely and falls past it -- which is the whole
	point of storing the rotation.
*/
@(test)
a_turned_box_collides_where_it_is_turned_to :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	// The floor, well below, so a crate that misses the slab has somewhere to
	// land and the test can say which happened.
	create_box_body(position = {0, -10.5, 0}, half_extents = {50, 0.5, 50})

	// Flat, this slab's top face would be y = 1. On its edge it is 0.1 thick in
	// X and 4 tall in Y, from -2 to 2.
	upright := linalg.quaternion_angle_axis_f32(math.PI * 0.5, {0, 0, 1})
	create_box_body(position = {0, 0, 0}, half_extents = {2, 0.1, 2}, rotation = upright)

	// Straight above the middle, where the flat slab would have caught it.
	over_the_middle := create_box_body(position = {0, 5, 0}, half_extents = {0.2, 0.2, 0.2}, type = .DYNAMIC)

	// Out at x = 1.5, over nothing at all once the slab is on its edge.
	over_the_side := create_box_body(position = {1.5, 5, 0}, half_extents = {0.2, 0.2, 0.2}, type = .DYNAMIC)

	run_for(3)

	// The one over the middle lands on the slab's upper end: 2 up from the
	// middle, plus its own half-height.
	middle := get_body_position(&over_the_middle)
	testing.expectf(t, abs(middle.y - 2.2) < 0.05, "over the middle rested at y = %v, want about 2.2", middle.y)

	// The one over the side falls past where a flat slab would have been, to
	// the floor at y = -10.
	side := get_body_position(&over_the_side)
	testing.expectf(t, side.y < -9.5, "over the side rested at y = %v, want the floor at about -9.8", side.y)
}

/*
	`offset` turns with the body, so `get_body_origin` gives back the position
	the body was made at whatever it was turned to.

	This is what a level's collider needs: the entity is drawn at its own
	origin, the collider is centred on the geometry, and the two must not drift
	apart when the entity is turned.
*/
@(test)
a_turned_body_keeps_its_offset_in_step_with_its_origin :: proc(t: ^testing.T) {
	init(gravity = {0, 0, 0})
	defer shutdown()

	// A model standing on its own origin: its bounds run 0 to 2 in Y, so the
	// collider's centre is a unit above where it is drawn.
	turn := linalg.quaternion_angle_axis_f32(math.PI * 0.5, {0, 1, 0})
	post := create_box_body(position = {3, 0, 4}, half_extents = {0.5, 1, 0.5}, offset = {0, 1, 0}, rotation = turn)

	origin := get_body_origin(&post)
	testing.expectf(t, near(origin, {3, 0, 4}), "origin came back as %v, want where it was made", origin)

	// A turn about Y leaves a straight-up offset alone, so the centre is still
	// a unit above; a turn about Z would not, which is what the next line
	// checks with the offset laid over sideways.
	testing.expectf(t, near(get_body_position(&post), {3, 1, 4}), "centre at %v", get_body_position(&post))

	tip  := linalg.quaternion_angle_axis_f32(math.PI * 0.5, {0, 0, 1})
	lain := create_box_body(position = {0, 0, 0}, half_extents = {0.5, 1, 0.5}, offset = {0, 1, 0}, rotation = tip)

	// Y up, turned a quarter about Z, becomes -X: the centre moved sideways,
	// and the origin still reads back as where it was made.
	testing.expectf(t, near(get_body_position(&lain), {-1, 0, 0}), "tipped centre at %v", get_body_position(&lain))
	testing.expectf(t, near(get_body_origin(&lain), {0, 0, 0}), "tipped origin at %v", get_body_origin(&lain))
}

// A capsule turned on its side, which a fallen log is and a player never is.
@(test)
a_turned_capsule_lies_along_the_axis_it_was_turned_to :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})

	// 1 long between its ends, 0.25 across: upright it is 1.5 tall and rests
	// with its centre at 0.75; on its side it rests at 0.25.
	lain := linalg.quaternion_angle_axis_f32(math.PI * 0.5, {0, 0, 1})
	log  := create_capsule_body(position = {0, 3, 0}, radius = 0.25, half_height = 0.5, type = .DYNAMIC, rotation = lain)

	run_for(3)

	y := get_body_position(&log).y
	testing.expectf(t, abs(y - 0.25) < 0.02, "the log rested at y = %v, want its radius, 0.25", y)
}

/*
	One body out of the world, with the rest left standing -- what unloading a
	level does.
*/
@(test)
a_destroyed_body_leaves_the_world_and_the_rest_of_it_alone :: proc(t: ^testing.T) {
	init()
	defer shutdown()

	floor := create_box_body(position = {0, -0.5, 0}, half_extents = {50, 0.5, 50})
	wall  := create_box_body(position = {0, 1, -3}, half_extents = {3, 1, 0.5})

	// The wall is there: a ray down the -Z axis finds it.
	before := cast_ray({0, 1, 0}, {0, 0, -10})
	testing.expect(t, is_body_hit(before, &wall), "the wall should be in the way")

	destroy_body(&wall)

	// Gone, and the `Body` names nothing rather than naming a freed slot.
	testing.expect_value(t, wall, Body{})
	testing.expect(t, !cast_ray({0, 1, 0}, {0, 0, -10}).hit, "nothing should be in the way now")

	// Destroying it twice is not a crash, and the floor is untouched: a crate
	// still lands on it.
	destroy_body(&wall)

	crate := create_box_body(position = {0, 3, -3}, half_extents = {0.2, 0.2, 0.2}, type = .DYNAMIC)
	run_for(2)
	testing.expectf(t, abs(get_body_position(&crate).y - 0.2) < 0.02,
		"the crate rested at %v, so the floor should still be there", get_body_position(&crate))

	_ = floor
}

// `shutdown` without a world, and twice over: nothing rather than a crash.
@(test)
shutdown_is_safe_without_a_world_and_twice_over :: proc(t: ^testing.T) {
	shutdown()

	init()
	create_box_body(position = {0, -0.5, 0}, half_extents = {10, 0.5, 10})
	shutdown()
	shutdown()

	testing.expect_value(t, tpi, Tether_Instance{})

	// And a world made after all that still works, so nothing was left behind.
	init()
	defer shutdown()

	create_box_body(position = {0, -0.5, 0}, half_extents = {10, 0.5, 10})
	crate := create_box_body(position = {0, 2, 0}, half_extents = {0.2, 0.2, 0.2}, type = .DYNAMIC)
	run_for(2)
	testing.expectf(t, abs(get_body_position(&crate).y - 0.2) < 0.02,
		"the crate rested at %v", get_body_position(&crate))
}
