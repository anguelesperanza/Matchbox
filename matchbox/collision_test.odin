#+build windows

package matchbox

import "core:testing"
import "core:sync"

@(test)
boxes_sharing_an_edge_do_not_collide_but_resting_on_top_is_contact :: proc(t:^testing.T) {
	// b is a platform from (0,0) to (4,1); a is 1 x 1
	b_min, b_max := [2]f32{0, 0}, [2]f32{4, 1}

	// Overlapping by half a unit: both
	testing.expect(t, is_bounding_box_collision({1, 0.5}, {2, 1.5}, b_min, b_max))
	testing.expect(t, is_bounding_box_contact({1, 0.5}, {2, 1.5}, b_min, b_max))

	// Standing exactly on top (a's bottom at b's top): contact, not collision
	testing.expect(t, is_bounding_box_collision({1, 1}, {2, 2}, b_min, b_max) == false)
	testing.expect(t, is_bounding_box_contact({1, 1}, {2, 2}, b_min, b_max))

	// Touching b's side, or hanging under it: neither
	testing.expect(t, is_bounding_box_contact({4, 0}, {5, 1}, b_min, b_max) == false)
	testing.expect(t, is_bounding_box_contact({1, -1}, {2, 0}, b_min, b_max) == false)

	// A gap above: neither
	testing.expect(t, is_bounding_box_contact({1, 1.1}, {2, 2.1}, b_min, b_max) == false)
}

@(test)
padding_pulls_the_collision_box_in_and_follows_flip_and_scale :: proc(t:^testing.T) {
	sprite := create_sprite(test_image()) // 64 x 32 pixels at 16 per unit: (-2,-1) to (2,1)
	sprite.bounding_box_padding = {16, 0, 0, 8} // left 1 unit, bottom 0.5 units

	min, max := calculate_sprite_collision_bounds(sprite)
	testing.expect_value(t, min, [2]f32{-1, -0.5})
	testing.expect_value(t, max, [2]f32{2, 1})

	// Facing the other way, the left padding moves to the right
	sprite.flip_x = true
	min, max = calculate_sprite_collision_bounds(sprite)
	testing.expect_value(t, min, [2]f32{-2, -0.5})
	testing.expect_value(t, max, [2]f32{1, 1})

	// Twice the size: the padding doubles with the picture
	sprite.flip_x = false
	sprite.scale = {2, 2}
	min, max = calculate_sprite_collision_bounds(sprite)
	testing.expect_value(t, min, [2]f32{-2, -1})
	testing.expect_value(t, max, [2]f32{4, 2})
}

@(test)
sprites_collide_through_their_padded_boxes :: proc(t:^testing.T) {
	a := create_sprite(test_image(), {0, 0, 0})
	b := create_sprite(test_image(), {3.5, 0, 0}) // pictures overlap by half a unit

	testing.expect(t, is_sprite_collision(a, b))

	// Pull a's right side in by a unit and the overlap is gone
	a.bounding_box_padding = {0, 0, 16, 0}
	testing.expect(t, is_sprite_collision(a, b) == false)

	// An animated sprite is a sprite (`using sprite`), so it can be passed as one
	animated:Animated_Sprite
	animated.sprite = create_sprite(test_image(), {0, 2, 0}) // standing on a's top edge
	testing.expect(t, is_sprite_contact(animated, a))
	testing.expect(t, is_sprite_collision(animated, a) == false)
}

@(test)
clamping_keeps_the_collision_box_inside_the_area :: proc(t:^testing.T) {
	area_min, area_max := [2]f32{-5, -5}, [2]f32{5, 5}

	sprite := create_sprite(test_image(), {4, -4.5, 7}) // reaches x 6 and y -5.5
	position := calculate_sprite_clamped_position(sprite, area_min, area_max)
	testing.expect_value(t, position, [3]f32{3, -4, 7})

	// Already inside: unchanged
	sprite.position = {0, 0, 7}
	testing.expect_value(t, calculate_sprite_clamped_position(sprite, area_min, area_max), [3]f32{0, 0, 7})

	// Wider than the area: centred across it, still pushed in on y
	sprite.scale = {4, 1} // 16 units wide
	sprite.position = {3, 4.5, 0}
	testing.expect_value(t, calculate_sprite_clamped_position(sprite, area_min, area_max), [3]f32{0, 4, 0})

	// The padded box is what is kept in, not the picture
	sprite.scale = {1, 1}
	sprite.bounding_box_padding = {0, 0, 16, 0} // box ends 1 unit inside the picture's right edge
	sprite.position = {4, 0, 0}
	testing.expect_value(t, calculate_sprite_clamped_position(sprite, area_min, area_max), [3]f32{4, 0, 0})
}

// The outline tests queue real render items, which writes `mbi`. Only these tests touch
// camera_active and the item lists, so a lock of their own keeps them off each other
// (the bottom screen tests' lock guards different fields)
@(private="file")
render_queue_lock:sync.Mutex

// The world rectangles {min, max} of what was queued: each item is the unit quad
// (-0.5..0.5) moved by its model matrix
@(private="file")
queued_rectangles :: proc(items:[]Render_Item) -> [][2][2]f32 {
	rectangles := make([][2][2]f32, len(items), context.temp_allocator)
	for item, i in items {
		low := item.model * [4]f32{-0.5, -0.5, 0, 1}
		high := item.model * [4]f32{0.5, 0.5, 0, 1}
		rectangles[i] = {{low.x, low.y}, {high.x, high.y}}
	}
	return rectangles
}

@(test)
outline_is_four_strips_inside_the_box :: proc(t:^testing.T) {
	sync.mutex_lock(&render_queue_lock)
	defer sync.mutex_unlock(&render_queue_lock)
	defer free_all(context.temp_allocator)

	saved_active, saved_items := mbi.camera_active, mbi.opaque_items
	mbi.camera_active = true
	mbi.opaque_items = make([dynamic]Render_Item, context.temp_allocator)
	defer {
		mbi.camera_active = saved_active
		mbi.opaque_items = saved_items
	}

	// A box from (0,0) to (4,2), sides 0.5 thick
	render_rectangle_outline({0, 0}, {4, 2}, 3, 0.5, {1, 0, 0, 1})
	testing.expect_value(t, len(mbi.opaque_items), 4)
	rectangles := queued_rectangles(mbi.opaque_items[:])
	testing.expect_value(t, rectangles[0], [2][2]f32{{0, 0}, {4, 0.5}}) // bottom, full width
	testing.expect_value(t, rectangles[1], [2][2]f32{{0, 1.5}, {4, 2}}) // top, full width
	testing.expect_value(t, rectangles[2], [2][2]f32{{0, 0.5}, {0.5, 1.5}}) // left, between them
	testing.expect_value(t, rectangles[3], [2][2]f32{{3.5, 0.5}, {4, 1.5}}) // right, between them
	for item in mbi.opaque_items {
		testing.expect_value(t, (item.model * [4]f32{0, 0, 0, 1}).z, 3)
	}

	// Too thick for a hole: one filled rectangle
	clear(&mbi.opaque_items)
	render_rectangle_outline({0, 0}, {4, 2}, 3, 1, {1, 0, 0, 1})
	testing.expect_value(t, len(mbi.opaque_items), 1)
	testing.expect_value(t, queued_rectangles(mbi.opaque_items[:])[0], [2][2]f32{{0, 0}, {4, 2}})

	// A sprite's outline is its padded collision box, just in front of it
	clear(&mbi.opaque_items)
	sprite := create_sprite(test_image(), {0, 0, 2}) // (-2,-1) to (2,1)
	sprite.bounding_box_padding = {16, 0, 0, 8} // box (-1,-0.5) to (2,1)
	render_bounding_box_outline(sprite, {0, 1, 0, 1}, 0.25)
	rectangles = queued_rectangles(mbi.opaque_items[:])
	testing.expect_value(t, rectangles[0], [2][2]f32{{-1, -0.5}, {2, -0.25}})
	testing.expect_value(t, rectangles[1], [2][2]f32{{-1, 0.75}, {2, 1}})
	testing.expect_value(t, (mbi.opaque_items[0].model * [4]f32{0, 0, 0, 1}).z, 2.01)
}
