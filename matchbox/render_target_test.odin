#+build windows

package matchbox

/*
	The maths of render targets, no GPU: where a picture lands on a screen, and where a window pixel is on the
	picture. Worked out by hand: each case's arithmetic is in its comment
*/

import "core:sync"
import "core:testing"

@(test)
integer_fit_is_the_largest_whole_multiple_centred :: proc(t:^testing.T) {
	// 480x272 into 960x544 is exactly x2 and fills the screen
	top_left, bottom_right := calculate_fit_rectangle({480, 272}, {960, 544}, .INTEGER)
	testing.expect_value(t, top_left, [2]f32{0, 0})
	testing.expect_value(t, bottom_right, [2]f32{960, 544})

	// 400x240 into 1920x1080: ratios 4.8 and 4.5, so x4 = 1600x960, centred: (1920-1600)/2 = 160, (1080-960)/2 = 60
	top_left, bottom_right = calculate_fit_rectangle({400, 240}, {1920, 1080}, .INTEGER)
	testing.expect_value(t, top_left, [2]f32{160, 60})
	testing.expect_value(t, bottom_right, [2]f32{1760, 1020})

	// A screen smaller than the picture still gets x1 (cropped), never x0: 400x240 into 200x100 is 400 wide centred at -100
	top_left, bottom_right = calculate_fit_rectangle({400, 240}, {200, 100}, .INTEGER)
	testing.expect_value(t, top_left, [2]f32{-100, -70})
	testing.expect_value(t, bottom_right, [2]f32{300, 170})
}

@(test)
fit_fill_and_stretch :: proc(t:^testing.T) {
	// FIT: 400x240 into 1920x1080 is x4.5 = 1800x1080, bars 60 on each side
	top_left, bottom_right := calculate_fit_rectangle({400, 240}, {1920, 1080}, .FIT)
	testing.expect_value(t, top_left, [2]f32{60, 0})
	testing.expect_value(t, bottom_right, [2]f32{1860, 1080})

	// FILL: x4.8 = 1920x1152, 36 cropped off the top and the bottom
	top_left, bottom_right = calculate_fit_rectangle({400, 240}, {1920, 1080}, .FILL)
	testing.expect_value(t, top_left, [2]f32{0, -36})
	testing.expect_value(t, bottom_right, [2]f32{1920, 1116})

	// STRETCH: the whole screen
	top_left, bottom_right = calculate_fit_rectangle({400, 240}, {1920, 1080}, .STRETCH)
	testing.expect_value(t, top_left, [2]f32{0, 0})
	testing.expect_value(t, bottom_right, [2]f32{1920, 1080})

	// Nothing to fit into gives nothing, not a divide by zero
	top_left, bottom_right = calculate_fit_rectangle({400, 240}, {0, 0}, .FIT)
	testing.expect_value(t, bottom_right, [2]f32{0, 0})
}

@(test)
window_pixels_map_back_onto_the_picture :: proc(t:^testing.T) {
	// 480x272 at x2 on 960x544: the window's (100, 50) is the target's (50, 25)
	position := calculate_target_position_in({480, 272}, {960, 544}, {100, 50}, .INTEGER)
	testing.expect_value(t, position, [2]f32{50, 25})

	// With bars: 400x240 on 1920x1080, INTEGER x4 from (160, 60). The picture's corner is the target's origin
	position = calculate_target_position_in({400, 240}, {1920, 1080}, {160, 60}, .INTEGER)
	testing.expect_value(t, position, [2]f32{0, 0})
	position = calculate_target_position_in({400, 240}, {1920, 1080}, {1760, 1020}, .INTEGER)
	testing.expect_value(t, position, [2]f32{400, 240})
	// Left of the picture, in the bar: outside 0..size, not clamped
	position = calculate_target_position_in({400, 240}, {1920, 1080}, {120, 60}, .INTEGER)
	testing.expect_value(t, position, [2]f32{-10, 0})

	// STRETCH is just the ratio of the sizes: the window's centre is the target's centre
	position = calculate_target_position_in({320, 180}, {1280, 720}, {640, 360}, .STRETCH)
	testing.expect_value(t, position, [2]f32{160, 90})
}

@(test)
sizes_come_from_the_screen_and_the_scale :: proc(t:^testing.T) {
	// Its own size wins
	testing.expect_value(t, calculate_render_target_size(480, 272, 0, {960, 544}), [2]i32{480, 272})
	// Neither: the screen's size, times the scale, and 1 when the scale is 0
	testing.expect_value(t, calculate_render_target_size(0, 0, 0, {960, 544}), [2]i32{960, 544})
	testing.expect_value(t, calculate_render_target_size(0, 0, 0.5, {960, 544}), [2]i32{480, 272})
	// Odd results round up, so no row is lost: 400 * 0.5 = 200, 240 * 0.5 = 120; 401 * 0.5 = 200.5 -> 201
	testing.expect_value(t, calculate_render_target_size(0, 0, 0.5, {401, 241}), [2]i32{201, 121})
	// Never below one pixel
	testing.expect_value(t, calculate_render_target_size(0, 0, 0.001, {10, 10}), [2]i32{1, 1})
}

@(test)
settings_defaults_have_a_depth_buffer_and_point_sampling :: proc(t:^testing.T) {
	settings := Render_Target_Settings{width = 64, height = 32}
	testing.expect_value(t, settings.no_depth, false)
	testing.expect_value(t, settings.filter, Filter_Mode.POINT)
}

// The internal resolution tests set the window size and the pointer, which the bottom screen tests read, so they share a lock
@(private="file")
Saved_Window :: struct {
	window_size:[4]i32,
	mouse_position:[2]i32,
	internal:Internal_Resolution_Settings,
}

@(private="file")
use_window :: proc(size:[2]i32, internal:Internal_Resolution_Settings) -> Saved_Window {
	sync.mutex_lock(&mbi_lock)
	saved := Saved_Window{mbi.window_size, mbi.mouse_position, mbi.render_target_state.internal}
	mbi.window_size = {size.x, size.y, 0, 0}
	mbi.render_target_state.internal = internal
	return saved
}

@(private="file")
restore_window :: proc(saved:Saved_Window) {
	mbi.window_size = saved.window_size
	mbi.mouse_position = saved.mouse_position
	mbi.render_target_state.internal = saved.internal
	sync.mutex_unlock(&mbi_lock)
}

@(test)
internal_resolution_is_off_until_asked_for :: proc(t:^testing.T) {
	saved := use_window({960, 544}, {})
	defer restore_window(saved)

	testing.expect_value(t, is_internal_resolution_on(), false)
	testing.expect_value(t, get_internal_resolution(), [2]i32{960, 544})

	mbi.render_target_state.internal = {scale = 0.5}
	testing.expect_value(t, is_internal_resolution_on(), true)
	testing.expect_value(t, get_internal_resolution(), [2]i32{480, 272})

	mbi.render_target_state.internal = {width = 640, height = 362}
	testing.expect_value(t, get_internal_resolution(), [2]i32{640, 362})
	// The pixel counts the plan quotes: 522240 at full size, 231680 at 640x362 (44%), 130560 at 480x272 (25%)
	testing.expect_value(t, 960 * 544, 522240)
	testing.expect_value(t, 640 * 362, 231680)
	testing.expect_value(t, 480 * 272, 130560)
}

@(test)
the_pointer_is_unscaled_through_the_fit :: proc(t:^testing.T) {
	saved := use_window({960, 544}, {scale = 0.5, fit = .INTEGER})
	defer restore_window(saved)

	// 480x272 at x2 fills the window: the window's (100, 50) is the picture's (50, 25)
	testing.expect_value(t, calculate_pointer_draw_position({100, 50}), [2]f32{50, 25})
	testing.expect_value(t, get_pointer_draw_size(), [2]f32{480, 272})

	// Through the mouse maths, with a camera 272 units tall (a unit a pixel at the internal size): x = 50 - 240, y = 136 - 25
	mbi.mouse_position = {100, 50}
	testing.expect_value(t, calculate_mouse_world_position(create_camera_2d(272)), [2]f32{-190, 111})

	// A window of 1920x1080 with a 400x240 picture at x4 from (160, 60): the window's (240, 100) is the picture's (20, 10)
	mbi.window_size = {1920, 1080, 0, 0}
	mbi.render_target_state.internal = {width = 400, height = 240, fit = .INTEGER}
	testing.expect_value(t, calculate_pointer_draw_position({240, 100}), [2]f32{20, 10})
	// And with the internal resolution off the pointer is the window's own
	mbi.render_target_state.internal = {}
	testing.expect_value(t, calculate_pointer_draw_position({240, 100}), [2]f32{240, 100})
}
