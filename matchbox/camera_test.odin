package matchbox

/*
	Camera follow and parallax -- the arithmetic
	--------------------------------------------
	Both of these are a couple of lines of maths whose failures are quiet: an
	easing that overshoots looks like a wobble somebody blames on the art, and a
	parallax layer at the wrong fraction just looks like the wrong art. Neither
	shows up as a crash, so both are pinned down here.

	No GPU is needed. `camera_follow` only touches `mbi.camera`, and the
	parallax offset is a pure function of a sprite and the camera -- the drawing
	is a separate procedure and is not what is in question.
*/

import "core:testing"

// The whole point: the camera closes the gap rather than teleporting across it.
@(test)
test_camera_follow_converges :: proc(t: ^testing.T) {
	mbi.camera = Camera{follow_speed = 4}

	target := [2]f32{100, 0}
	before := mbi.camera.position

	camera_follow(target, 1.0 / 60.0)

	moved := mbi.camera.position.x - before.x
	testing.expect(t, moved > 0, "the camera did not move toward the target")
	testing.expect(t, mbi.camera.position.x < target.x,
		"the camera arrived in one step, which is a snap and not a follow")

	// Repeated steps keep closing the gap and settle on the target.
	for _ in 0 ..< 600 do camera_follow(target, 1.0 / 60.0)

	gap := target.x - mbi.camera.position.x
	testing.expect(t, gap < 0.01, "the camera never arrived")
}

/*
	`follow_speed * delta_time` past 1 is reachable on a stalled frame, and the
	unclamped form overshoots there -- the camera flies past the target and
	oscillates, worse the larger the product.
*/
@(test)
test_camera_follow_does_not_overshoot :: proc(t: ^testing.T) {
	mbi.camera = Camera{follow_speed = 50}

	target := [2]f32{100, 0}
	camera_follow(target, 1.0) // factor of 50, absurd on purpose

	testing.expect_value(t, mbi.camera.position, target)
}

// The zero value. A camera nobody configured stays where it was put rather
// than snapping to whatever gets passed in.
@(test)
test_camera_follow_zero_speed_does_nothing :: proc(t: ^testing.T) {
	mbi.camera = Camera{position = {10, 20}}

	camera_follow({999, 999}, 1.0 / 60.0)

	testing.expect_value(t, mbi.camera.position, [2]f32{10, 20})
}

// A negative speed would ease the camera away from its target, which is never
// what anyone meant, so it is read as "do not follow".
@(test)
test_camera_follow_negative_speed_does_nothing :: proc(t: ^testing.T) {
	mbi.camera = Camera{position = {10, 20}, follow_speed = -5}

	camera_follow({999, 999}, 1.0 / 60.0)

	testing.expect_value(t, mbi.camera.position, [2]f32{10, 20})
}

/*
	A layer at `speed` should end up on screen at `base - camera * speed`, which
	is what "follows the camera by that fraction" means. `parallax_position`
	returns the pre-`screen_pos` value, so the assertion is against
	`base + camera * (1 - speed)`.
*/
@(test)
test_parallax_moves_by_its_fraction :: proc(t: ^testing.T) {
	mbi.camera = Camera{position = {100, 40}, active = true}

	half := Sprite{}
	half.parallax_speed = 0.5

	// base {0,0} + camera {100,40} * 0.5
	testing.expect_value(t, parallax_position(half), [2]f32{50, 20})

	// The same layer moved in the world keeps its own position underneath.
	half.position = {8, 3}
	testing.expect_value(t, parallax_position(half), [2]f32{58, 23})
}

// Speed 1 is an ordinary world-space sprite: the offset cancels and the layer
// is drawn exactly where it says it is.
@(test)
test_parallax_speed_one_matches_the_world :: proc(t: ^testing.T) {
	mbi.camera = Camera{position = {100, 40}, active = true}

	world := Sprite{}
	world.parallax_speed = 1
	world.position = {7, 9}

	testing.expect_value(t, parallax_position(world), [2]f32{7, 9})
}

// Speed 0 pins the layer: the offset cancels the camera, so it holds still on
// screen however far the camera travels.
@(test)
test_parallax_speed_zero_is_pinned :: proc(t: ^testing.T) {
	pinned := Sprite{}
	pinned.position = {5, 5}

	mbi.camera = Camera{position = {100, 40}, active = true}
	near := parallax_position(pinned)

	mbi.camera.position = {900, -300}
	far := parallax_position(pinned)

	// It lands wherever the camera is, which is what cancels out in screen_pos
	// and leaves it stationary.
	testing.expect_value(t, near, [2]f32{105, 45})
	testing.expect_value(t, far, [2]f32{905, -295})
}

/*
	Outside begin_drawing_2d there is no camera offset for the effect to be a
	fraction of, so a layer falls back to its own position rather than being
	shifted by a camera that is not being applied.
*/
@(test)
test_parallax_is_inert_without_an_active_camera :: proc(t: ^testing.T) {
	mbi.camera = Camera{position = {100, 40}, active = false}

	layer := Sprite{}
	layer.position = {5, 5}
	layer.parallax_speed = 0

	testing.expect_value(t, parallax_position(layer), [2]f32{5, 5})
}

// A set that was declared and never filled -- an optional layer a game did not
// end up using -- still has to be safe to take down.
@(test)
test_destroy_parallax_survives_a_zero_set :: proc(t: ^testing.T) {
	empty: Parallax_Sprites
	destroy_parallax(&empty)

	testing.expect_value(t, len(empty.sprites), 0)
}

// parallax_add states the depth in one place, and defaults to moving with the
// world so an unstated layer behaves like an ordinary sprite.
@(test)
test_parallax_add_writes_the_speed :: proc(t: ^testing.T) {
	set := create_parallax()
	defer destroy_parallax(&set)

	parallax_add(&set, Sprite{}, 0.25)
	parallax_add(&set, Sprite{})

	testing.expect_value(t, len(set.sprites), 2)
	testing.expect_value(t, set.sprites[0].parallax_speed, f32(0.25))
	testing.expect_value(t, set.sprites[1].parallax_speed, f32(1))
}
