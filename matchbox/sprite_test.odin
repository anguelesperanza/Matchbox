#+build windows

package matchbox

import "core:testing"

// A 64x32 pixel image with no GPU behind it, one frame
test_image :: proc() -> Texture {
	return Texture{width = 64, height = 32, columns = 1, rows = 1, frame_count = 1, pixels_per_unit = 16}
}

@(test)
bounds_follow_the_pivot :: proc(t:^testing.T) {
	sprite := create_sprite(test_image(), {10, 5, 0}) // 4 x 2 units, pivot in the middle
	min, max := get_sprite_bounds(sprite)
	testing.expect_value(t, min, [2]f32{8, 4})
	testing.expect_value(t, max, [2]f32{12, 6})

	sprite.pivot = {0, 0} // the bottom left corner sits at the position
	min, max = get_sprite_bounds(sprite)
	testing.expect_value(t, min, [2]f32{10, 5})
	testing.expect_value(t, max, [2]f32{14, 7})
}

@(test)
bounds_follow_scale_and_source :: proc(t:^testing.T) {
	sprite := create_sprite(test_image(), {0, 0, 0})
	sprite.scale = {2, 2}
	min, max := get_sprite_bounds(sprite)
	testing.expect_value(t, max - min, [2]f32{8, 4})

	sprite.scale = {1, 1}
	sprite.source = {0, 0, 16, 16} // a 1 x 1 unit crop
	min, max = get_sprite_bounds(sprite)
	testing.expect_value(t, max - min, [2]f32{1, 1})
}

@(test)
point_in_rect_includes_the_edges :: proc(t:^testing.T) {
	min := [2]f32{0, 0}
	max := [2]f32{4, 2}
	testing.expect_value(t, is_point_in_rect({2, 1}, min, max), true)
	testing.expect_value(t, is_point_in_rect({0, 0}, min, max), true) // a corner
	testing.expect_value(t, is_point_in_rect({4, 2}, min, max), true)
	testing.expect_value(t, is_point_in_rect({4.01, 1}, min, max), false)
	testing.expect_value(t, is_point_in_rect({2, -0.01}, min, max), false)
}

@(test)
point_in_sprite_bounds :: proc(t:^testing.T) {
	sprite := create_sprite(test_image(), {10, 5, 0})
	min, max := get_sprite_bounds(sprite)
	testing.expect_value(t, is_point_in_rect({11, 5.5}, min, max), true)
	testing.expect_value(t, is_point_in_rect({13, 5}, min, max), false)
}
