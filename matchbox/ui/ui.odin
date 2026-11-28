#+build windows

package ui

/*
	UI
	==
	A toolkit for tools: the pointer and the keyboard as widgets see them, text, flat drawing with a clip that nests, and the
	widgets a level editor is built from (button, toggle, text field, number field, scroll view, dropdown, context menu,
	modal, status line). `import "matchbox/ui"` beside `import "matchbox"`, the way `matchbox/level` is imported, so a game
	that only draws sprites does not carry it. PC only: it needs a mouse and the clip.

	**Screen units, +Y up.** Everything is measured in the units of Matchbox's screen pass (set_screen_height), the origin
	at the middle of the window. begin_frame sets the screen height to the window's height divided by the UI scale, so at a
	scale of 1 a unit is a window pixel and at 1.5 a 1920 wide window lays out as 1280. Every draw, hit test and pointer
	position agrees, and text is baked at the scaled size so it stays sharp. Layout runs downwards while +Y is up: a
	panel's rows go from its top edge towards smaller y.

	**One rectangle convention.** A `Rectangle` is `min` (bottom left) and `max` (top right), the form render_rectangle_outline
	and calculate_visible_rectangle already use. There is no pivot. `create_rectangle` builds one from a top-left corner and a
	size, which is how a layout is usually thought of.

	**Immediate mode, ordered by input.** A widget draws itself and answers in one call, and nothing is kept between frames
	but what the caller holds (a `Dropdown`, a `Text_Field`). There are no callbacks. What opens out over the screen (a
	dropdown's list, a context menu, a modal) claims the pointer first (claim_pointer) so nothing under it answers the same
	click, and is drawn last so it is on top: the screen pass paints in submission order, which is what makes that work.

	**One global**, `ui_state`, for the reason CLAUDE.md gives for `mbi`: an immediate-mode API cannot take the pointer's
	state as an argument at every call. A test writes `ui_state.input` to drive a widget without a window. Tests share it, so
	run them one at a time: `odin test matchbox/ui -define:ODIN_TEST_THREADS=1`.

	Nothing draws without a screen pass: a test can run a whole panel for its input and layout and the drawing half does
	nothing.
*/

import mb ".."

// A rectangle of the screen: `min` the bottom left corner, `max` the top right
Rectangle :: struct {
	min: [2]f32,
	max: [2]f32,
}

WHITE :: [4]f32{1, 1, 1, 1}
BLACK :: [4]f32{0, 0, 0, 1}

UI_State :: struct {
	input: Input,

	// The multiplier from units to window pixels: set by set_scale, 1 until then
	scale: f32,

	// Counted by begin_frame, for the widgets that must ignore the click that opened them on the frame it happened
	frame: u64,

	// Seconds since the window opened, as of begin_frame. A status line's fade and a caret's blink run off this, so a test can set it
	time: f64,

	fonts:         Fonts,
	font_settings: Font_Settings,
	clip:          Clip_Stack,

	cursor_wanted: mb.Cursor_Shape,
	cursor_shown:  mb.Cursor_Shape,
}

ui_state := UI_State {
	scale = 1,
	font_settings = {
		bytes = mb.DEFAULT_FONT_BYTES,
		size = 26,
		line_spacing = 0.15,
	},
}

/*
	Starts a frame: reads Matchbox's input into `ui_state.input`, counts the frame and the clock, sets the screen height from
	the scale, and forgets last frame's claim on the pointer. Call once a frame, before anything asks about the pointer, and
	before the screen pass starts
*/
begin_frame :: proc() {
	ui_state.frame += 1
	ui_state.time = mb.get_time()
	mb.set_screen_height(f32(mb.get_window_size()[1]) / get_scale())
	read_input(&ui_state.input)
	ui_state.cursor_wanted = .ARROW
}

/*Ends a frame: shows the pointer shape asked for. After everything that might ask for one, so the last widget to ask wins: the edge being dragged rather than the panel under it*/
end_frame :: proc() {
	if ui_state.cursor_wanted != ui_state.cursor_shown {
		mb.set_cursor_shape(ui_state.cursor_wanted)
		ui_state.cursor_shown = ui_state.cursor_wanted
	}
}

/*Frees the fonts. Call it before the window closes: their textures are the GPU's*/
shutdown :: proc() {
	destroy_fonts(&ui_state.fonts)
}

/*Draws everything bigger from the next frame: the unit becomes 1 / `scale` window pixels. Zero or less is 1*/
set_scale :: proc(scale: f32) {
	ui_state.scale = scale if scale > 0 else 1
}

get_scale :: proc() -> f32 {
	return ui_state.scale if ui_state.scale > 0 else 1
}

/*The scale the operating system draws other programs at on this window's display: 1.5 for Windows at 150 percent*/
get_display_scale :: proc() -> f32 {
	return mb.get_display_scale()
}

/*The whole screen as a rectangle, in units: what a layout divides up. Wider or narrower as the window is; 1280 by 720 with no window*/
get_screen_rectangle :: proc() -> Rectangle {
	if mb.get_window_size()[1] <= 0 do return {min = {-640, -360}, max = {640, 360}}
	low, high := mb.calculate_visible_rectangle()
	return {min = low, max = high}
}

/*A size in units as window pixels: what a render target drawn into a rectangle of this size should be, so it is not stretched*/
calculate_pixels :: proc(size: [2]f32) -> [2]f32 {
	return size * get_scale()
}

// ---- rectangles ------------------------------------------------------------------

/*A rectangle from its top-left corner and its size. Layout starts at a top edge and goes down, so this is the usual way to make one*/
create_rectangle :: proc(top_left: [2]f32, size: [2]f32) -> Rectangle {
	return {min = {top_left.x, top_left.y - size.y}, max = {top_left.x + size.x, top_left.y}}
}

/*A rectangle `size` big, centred on `centre`*/
create_rectangle_centred :: proc(centre, size: [2]f32) -> Rectangle {
	return {min = centre - size * 0.5, max = centre + size * 0.5}
}

calculate_rectangle_size :: proc(rectangle: Rectangle) -> [2]f32 {
	return rectangle.max - rectangle.min
}

calculate_rectangle_centre :: proc(rectangle: Rectangle) -> [2]f32 {
	return (rectangle.min + rectangle.max) * 0.5
}

get_rectangle_top_left :: proc(rectangle: Rectangle) -> [2]f32 {
	return {rectangle.min.x, rectangle.max.y}
}

/*Whether a point is inside a rectangle, edges included. The plain geometric test: is_pointer_over_rectangle also asks the clip*/
is_point_in_rectangle :: proc(point: [2]f32, rectangle: Rectangle) -> bool {
	return point.x >= rectangle.min.x && point.x <= rectangle.max.x && point.y >= rectangle.min.y && point.y <= rectangle.max.y
}

/*The area two rectangles share; an empty one (no area) when they do not meet*/
calculate_rectangle_intersection :: proc(a, b: Rectangle) -> Rectangle {
	low := [2]f32{max(a.min.x, b.min.x), max(a.min.y, b.min.y)}
	high := [2]f32{min(a.max.x, b.max.x), min(a.max.y, b.max.y)}
	return {min = low, max = {max(high.x, low.x), max(high.y, low.y)}}
}
