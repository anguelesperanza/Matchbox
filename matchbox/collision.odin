package matchbox

/*
	Collision
	=========
	Rectangle tests for 2D games: whether two sprites overlap, whether one is
	resting on another, keeping a sprite on screen, and the mouse over a sprite.

	Matchbox only answers; it never moves anything. A game asks on the frame it
	cares and decides what hitting means -- stop, bounce, take damage.

	Everything is in world units with +Y up, as boxes of `min` (bottom left) and
	`max` (top right) -- the shape calculate_sprite_bounds returns. Rotation is
	not counted: a rotated sprite collides as the box it would have unrotated.

	Brought over from `main`'s sprite.odin, where boxes were {left, top, right,
	bottom} in pixels with +Y down. The tests are the same; which edge is "the
	bottom" is the one thing that turned over (see is_bounding_box_contact).
*/

/*Whether two boxes overlap. Strictly: two boxes sharing an edge do not count, which
is what stops a character standing exactly on a platform from being reported as
inside it every frame -- see is_bounding_box_contact for the opposite*/
is_bounding_box_collision :: proc(a_min, a_max, b_min, b_max:[2]f32) -> bool {
	return a_min.x < b_max.x &&
		a_max.x > b_min.x &&
		a_min.y < b_max.y &&
		a_max.y > b_min.y
}

/*The same test as is_bounding_box_collision, except that `a` touching the top of `b`
counts. A character standing on a platform is exactly in contact with it and not
overlapping it, so the overlap test would say "not standing on anything" on the very
frame it lands. Only a's bottom on b's top is relaxed: touching from the side or from
below is still not contact, so walking into a wall does not count as standing on it*/
is_bounding_box_contact :: proc(a_min, a_max, b_min, b_max:[2]f32) -> bool {
	return a_min.x < b_max.x &&
		a_max.x > b_min.x &&
		a_min.y <= b_max.y &&
		a_max.y > b_min.y
}

/*The box a sprite collides as, in world units: its picture's bounds pulled in by
`bounding_box_padding`. `min` is the bottom left, `max` the top right.

The padding is in the image's pixels, so it is turned into world units the same way
the picture is (pixels_per_unit, then scale) and stays in step with the art when the
sprite is scaled. With `flip_x` left and right swap, so a hat pulled in on the left
stays on the hat when the character turns round*/
calculate_sprite_collision_bounds :: proc(sprite:Sprite) -> (min, max:[2]f32) {
	min, max = calculate_sprite_bounds(sprite)
	if sprite.pixels_per_unit <= 0 do return

	padding := sprite.bounding_box_padding
	left, top, right, bottom := padding[0], padding[1], padding[2], padding[3]
	if sprite.flip_x == true do left, right = right, left

	to_world := sprite.scale / sprite.pixels_per_unit
	min += [2]f32{left, bottom} * to_world
	max -= [2]f32{right, top} * to_world
	return
}

/*Whether two sprites' collision boxes overlap (see is_bounding_box_collision)*/
is_sprite_collision :: proc(a, b:Sprite) -> bool {
	a_min, a_max := calculate_sprite_collision_bounds(a)
	b_min, b_max := calculate_sprite_collision_bounds(b)
	return is_bounding_box_collision(a_min, a_max, b_min, b_max)
}

/*Whether sprite `a` overlaps or is resting on top of sprite `b` (see is_bounding_box_contact).
For "is the player standing on this platform"*/
is_sprite_contact :: proc(a, b:Sprite) -> bool {
	a_min, a_max := calculate_sprite_collision_bounds(a)
	b_min, b_max := calculate_sprite_collision_bounds(b)
	return is_bounding_box_contact(a_min, a_max, b_min, b_max)
}

/*
	The sprite's position moved so its collision box stays inside the box `area_min`
	to `area_max` -- usually what the camera sees:

		view_min, view_max := mb.calculate_camera_visible_rectangle(camera, mb.calculate_window_aspect())
		player.position = mb.calculate_sprite_clamped_position(player, view_min, view_max)

	Returns the position rather than writing it, so the caller decides whether hitting
	the edge also means stopping, bouncing or wrapping. A sprite wider or taller than
	the area is centred in it on that axis, since it cannot fit either way. z is kept.

	`main`'s version read the window and the letterbox itself. Here the area is passed
	in, because which camera the sprite is seen through is the game's to say -- the
	window is not the world on this branch.
*/
calculate_sprite_clamped_position :: proc(sprite:Sprite, area_min, area_max:[2]f32) -> [3]f32 {
	position := sprite.position
	min, max := calculate_sprite_collision_bounds(sprite)

	for axis in 0..<2 {
		if max[axis] - min[axis] > area_max[axis] - area_min[axis] {
			position[axis] += (area_min[axis] + area_max[axis]) * 0.5 - (min[axis] + max[axis]) * 0.5
		} else if min[axis] < area_min[axis] {
			position[axis] += area_min[axis] - min[axis]
		} else if max[axis] > area_max[axis] {
			position[axis] -= max[axis] - area_max[axis]
		}
	}
	return position
}

/*Whether the mouse is over a sprite's picture, as seen through `camera`. The picture's
bounds, not the collision box: padding is for bumping into things, and a click on a hat
is still a click on the character. Rotation is not counted*/
is_mouse_over_sprite :: proc(sprite:Sprite, camera:Camera) -> bool {
	min, max := calculate_sprite_bounds(sprite)
	return is_point_in_rectangle(calculate_mouse_world_position(camera), min, max)
}

/*
	Draws a sprite's collision box as an outline, for seeing what the game collides
	with while tuning `bounding_box_padding`. `thickness` is in world units.

	Drawn `in_front` world units nearer the camera than the sprite (the camera looks
	down -Z, so that is a bigger z). At the sprite's own z the outline and the picture
	would tie in the depth test, and which one showed would depend on draw order.
*/
render_bounding_box_outline :: proc(sprite:Sprite, color:[4]f32, thickness:f32, in_front:f32 = 0.01) {
	min, max := calculate_sprite_collision_bounds(sprite)
	render_rectangle_outline(min, max, sprite.position.z + in_front, thickness, color)
}
