#+build windows

package matchbox

import "core:sync"
import "core:testing"

// Tests run on several threads at once, and these all use the one global `mbi`. save_state
// takes this lock and restore_state gives it back, so only one of them runs at a time
mbi_lock:sync.Mutex // package-level: the internal resolution tests set the window size too (render_target_test.odin)

// The state these tests touch, put back afterwards so one test cannot leak into the next
@(private="file")
Saved_State :: struct {
	layout:Bottom_Screen_Layout,
	window_size:[4]i32,
	screen_height:f32,
}

@(private="file")
save_state :: proc() -> Saved_State {
	sync.mutex_lock(&mbi_lock)
	return {mbi.bottom_screen_layout, mbi.window_size, mbi.screen_height}
}

@(private="file")
restore_state :: proc(saved:Saved_State) {
	mbi.bottom_screen_layout = saved.layout
	mbi.window_size = saved.window_size
	mbi.screen_height = saved.screen_height
	sync.mutex_unlock(&mbi_lock)
}

@(test)
bottom_screen_starts_hidden :: proc(t:^testing.T) {
	// A fresh Matchbox_Info, as at init, before any game call
	fresh:Matchbox_Info
	testing.expect_value(t, fresh.bottom_screen_layout, Bottom_Screen_Layout.HIDDEN)
}

@(test)
visibility_follows_the_layout :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	set_bottom_screen(.FULLSCREEN)
	testing.expect_value(t, is_bottom_screen_visible(), true)
	testing.expect_value(t, get_bottom_screen_layout(), Bottom_Screen_Layout.FULLSCREEN)

	set_bottom_screen(.HIDDEN)
	testing.expect_value(t, is_bottom_screen_visible(), false)

	// There is no console on one surface, so it is the same as HIDDEN
	set_bottom_screen(.CONSOLE)
	testing.expect_value(t, is_bottom_screen_visible(), false)
}

// The game draws every pass every frame; the layout decides which ones reach the window.
// camera_start throws a top pass away when this says so, and bottom_screen_start its own pass
// when the bottom screen is not visible: exactly one of the two is shown, whatever the layout
@(test)
the_top_passes_hide_while_the_bottom_screen_fills_the_window :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	for layout in Bottom_Screen_Layout {
		set_bottom_screen(layout)
		top_shown := is_top_screen_hidden() == false
		bottom_shown := is_bottom_screen_visible()
		testing.expectf(t, top_shown != bottom_shown, "%v: the top shown is %v and the bottom shown is %v", layout, top_shown, bottom_shown)
		testing.expect_value(t, bottom_shown, layout == .FULLSCREEN)
	}
}

@(test)
bottom_screen_fills_a_wide_window :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.screen_height = 12
	mbi.window_size = {1600, 800, 0, 0} // aspect 2
	min, max := calculate_bottom_screen_visible_rectangle()
	testing.expect_value(t, min, [2]f32{-12, -6}) // the HUD's height, the window's width
	testing.expect_value(t, max, [2]f32{12, 6})
}

@(test)
bottom_screen_keeps_its_width_in_a_narrow_window :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.screen_height = 12
	mbi.window_size = {800, 800, 0, 0} // square: narrower than 4:3
	min, max := calculate_bottom_screen_visible_rectangle()
	testing.expect_value(t, max.x - min.x, 16) // 4:3 of 12, not cut off
	testing.expect_value(t, max.y - min.y, 16) // so the view grew taller
}

@(test)
bottom_screen_anchors_follow_the_window :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)

	mbi.screen_height = 12
	mbi.window_size = {1600, 800, 0, 0}
	testing.expect_value(t, calculate_bottom_screen_anchor_position(.TOP_LEFT), [3]f32{-12, 6, 0})
	testing.expect_value(t, calculate_bottom_screen_anchor_position(.BOTTOM_RIGHT, {-1, 1}), [3]f32{11, -5, 0})
	testing.expect_value(t, calculate_bottom_screen_anchor_position(.CENTER), [3]f32{0, 0, 0})
}

@(test)
bottom_screen_mouse_is_in_screen_units :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)
	saved_mouse := mbi.mouse_position
	defer mbi.mouse_position = saved_mouse

	// 512 units in a 512 pixel tall window: one unit is one pixel, so the sums are exact
	mbi.screen_height = 512
	mbi.window_size = {1024, 512, 0, 0}
	set_bottom_screen(.FULLSCREEN)

	mbi.mouse_position = {256, 128} // a quarter across, a quarter down
	position, inside := calculate_mouse_bottom_screen_position()
	testing.expect_value(t, position, [2]f32{-256, 128})
	testing.expect_value(t, inside, true)
}

@(test)
bottom_screen_mouse_is_not_inside_when_hidden_or_outside :: proc(t:^testing.T) {
	saved := save_state()
	defer restore_state(saved)
	saved_mouse := mbi.mouse_position
	defer mbi.mouse_position = saved_mouse

	mbi.screen_height = 512
	mbi.window_size = {1024, 512, 0, 0}

	mbi.mouse_position = {256, 128}
	set_bottom_screen(.HIDDEN)
	_, inside := calculate_mouse_bottom_screen_position()
	testing.expect_value(t, inside, false) // hidden: nothing to click

	set_bottom_screen(.FULLSCREEN)
	mbi.mouse_position = {0, 0}
	_, inside = calculate_mouse_bottom_screen_position()
	testing.expect_value(t, inside, true) // the corner pixel is on the screen

	mbi.mouse_position = {-1, 100}
	_, inside = calculate_mouse_bottom_screen_position()
	testing.expect_value(t, inside, false) // outside the window
}
