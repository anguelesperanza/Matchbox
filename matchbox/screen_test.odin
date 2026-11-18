#+build windows

package matchbox

import "core:testing"

@(test)
visible_rect_follows_aspect :: proc(t:^testing.T) {
	cam := create_screen_camera(10)
	min, max := camera_visible_rect(cam, 2)
	testing.expect_value(t, min, [2]f32{-10, -5})
	testing.expect_value(t, max, [2]f32{10, 5})

	min, max = camera_visible_rect(cam, 1) // narrower window, same height
	testing.expect_value(t, min, [2]f32{-5, -5})
	testing.expect_value(t, max, [2]f32{5, 5})
}

@(test)
anchors_pin_to_the_corners :: proc(t:^testing.T) {
	cam := create_screen_camera(10)

	testing.expect_value(t, camera_anchor_position(cam, 2, .TOP_LEFT), [3]f32{-10, 5, 0})
	testing.expect_value(t, camera_anchor_position(cam, 2, .BOTTOM_RIGHT), [3]f32{10, -5, 0})
	testing.expect_value(t, camera_anchor_position(cam, 2, .CENTER), [3]f32{0, 0, 0})
	testing.expect_value(t, camera_anchor_position(cam, 2, .TOP), [3]f32{0, 5, 0})
	testing.expect_value(t, camera_anchor_position(cam, 2, .LEFT), [3]f32{-10, 0, 0})
}

@(test)
offset_is_plain_addition :: proc(t:^testing.T) {
	cam := create_screen_camera(10)
	testing.expect_value(t, camera_anchor_position(cam, 2, .TOP_LEFT, {1, -1}), [3]f32{-9, 4, 0})
	testing.expect_value(t, camera_anchor_position(cam, 2, .BOTTOM_RIGHT, {-1, 1}), [3]f32{9, -4, 0})
}

@(test)
anchors_follow_the_window_shape :: proc(t:^testing.T) {
	cam := create_screen_camera(10)
	wide := camera_anchor_position(cam, 2, .TOP_LEFT)
	wider := camera_anchor_position(cam, 4, .TOP_LEFT)
	testing.expect_value(t, wide.y, wider.y) // the same height
	testing.expect(t, wider.x < wide.x)      // the corner moved outwards with the window
}

@(test)
screen_camera_is_marked :: proc(t:^testing.T) {
	testing.expect_value(t, create_screen_camera(10).screen, true)
	testing.expect_value(t, create_camera_2d(10).screen, false)
}
