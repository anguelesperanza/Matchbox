package matchbox

import "core:math"
import "core:math/linalg"

/*
	Render targets
	==============
	Drawing into a texture instead of the screen, then drawing that texture back, bigger or smaller.
	Shared by every target; the GPU objects and the bind/unbind are each backend's
	(render_target_<target>.odin).

		scene := mb.create_render_target({width = 480, height = 272})
		defer mb.destroy(&scene)

		mb.render_start()
		mb.render_target_start(&scene, mb.SKY_BLUE)   // every target first, then the screen
			mb.camera_start(camera); /* world */ mb.camera_end()
		mb.render_target_end()

		mb.clear_background(mb.BLACK)
		mb.render_upscaled_target(scene, .INTEGER)
		mb.screen_start(); /* a crisp HUD */ mb.screen_end()
		mb.render_end()

	**While a target is active it is "the window"** for everything that measures one: a camera's aspect,
	`screen_start`'s HUD and its anchors, `calculate_visible_rectangle`, `pixel_snap`, billboards'
	`screen_size`. A `screen_start` inside `render_target_start` is laid out in the target's pixels (a
	chunky HUD); one after `render_target_end` is in screen pixels (a crisp one).

	**Every target is drawn before the screen, on every platform.** The Vita's GPU cannot interleave
	scenes (a target is one scene, the screen another, and the screen's cannot be reopened), so that
	order is the rule everywhere rather than the one that makes a PC game fail on a Vita.
	`clear_background` on the screen is allowed first: the Vita holds it until the screen scene opens.

	The target is the same size for ever (it does not follow a window resize), and does not nest.
*/

Fit_Mode :: enum {
	FIT, // the whole picture, aspect kept, bars at the sides or the top
	INTEGER, // the largest whole-number multiple that fits, centred: pixel-perfect, never blurry
	FILL, // aspect kept, covers the whole screen, the overflow cropped
	STRETCH, // the whole screen, aspect ignored
}

/*What a target is made like. A bare `{width = 480, height = 272}` has a depth buffer, so it works for 3D*/
Render_Target_Settings :: struct {
	width:i32, // pixels. 0 with height 0 = the size of the screen it is made for, times `scale`
	height:i32,
	scale:f32, // used only when width and height are 0: the screen's size times this. 0.5 = a quarter of the pixels. 0 means 1
	filter:Filter_Mode, // how it is sampled when drawn bigger. POINT (the zero value) is pixel-perfect; LINEAR smooths
	no_depth:bool, // a 2D-only target has no depth buffer, which saves memory (the 3DS has 6 MB of VRAM). A world camera cannot draw into it
}

/*A texture the GPU draws into*/
Render_Target :: struct {
	using backend:Backend_Render_Target, // the colour and depth GPU objects, which differ per target
	texture:Texture, // the colour: draw it with render_sprite, put it on a model, or use render_upscaled_target. The target owns it: do not destroy_sprite a sprite made from it, destroy the target
	width:i32, // the size that was asked for (on the 3DS the GPU object is padded up to a power of two)
	height:i32,
	has_depth:bool,
}

/*How the whole game is drawn smaller (or bigger) than the screen, then scaled to it. The zero value is off*/
Internal_Resolution_Settings :: struct {
	width:i32, // pixels. 0 with height 0 and scale 0 = off
	height:i32,
	scale:f32, // or the fraction of the screen's size, 0.5 = a quarter of the pixels
	filter:Filter_Mode,
	fit:Fit_Mode,
}

/*What `mbi` holds about targets (render_target.odin)*/
Render_Target_State :: struct {
	active:Render_Target, // a copy of the one between render_target_start and _end (a pointer would trip the compiler's stack-memory warning at every call)
	is_active:bool,
	screen_drawn:bool, // something has been drawn to the screen this frame, so a target can no longer start
	internal:Internal_Resolution_Settings,
	internal_target:Render_Target, // the one set_internal_resolution makes, remade when its size changes
	internal_frame:bool, // render_start began the internal target and render_end has to finish it
	suspended:Render_Target, // the 3DS: the active target, set aside while the bottom screen is drawn
	suspended_active:bool,
}

/*The size of the screen being drawn for: the window on PC and the Vita, the top screen on the 3DS*/
@(private)
get_screen_size :: proc() -> [2]i32 {
	return {mbi.window_size[0], mbi.window_size[1]}
}

/*What a camera measures as its window: the active target's size, else the screen's*/
@(private)
get_draw_size :: proc() -> [2]i32 {
	if mbi.render_target_state.is_active {
		return {mbi.render_target_state.active.width, mbi.render_target_state.active.height}
	}
	return get_screen_size()
}

/*The pixels a target gets: its own size, or the screen's times `scale`, rounded up so an odd size loses no row*/
@(private)
calculate_render_target_size :: proc(width, height:i32, scale:f32, screen:[2]i32) -> [2]i32 {
	if width > 0 && height > 0 do return {width, height}
	ensure(width == 0 && height == 0, "A render target needs both a width and a height, or neither")
	factor := scale if scale > 0 else 1
	// In f64, with a hair taken off, so a size that is a whole number stays one (960 * 1 is not 961)
	return {max(1, i32(math.ceil(f64(screen.x) * f64(factor) - 1e-6))), max(1, i32(math.ceil(f64(screen.y) * f64(factor) - 1e-6)))}
}

/*Where a picture of `source` pixels lands on a screen of `screen` pixels: the corners, top-left origin, y down*/
@(private)
calculate_fit_rectangle :: proc(source, screen:[2]f32, fit:Fit_Mode) -> (top_left, bottom_right:[2]f32) {
	if source.x <= 0 || source.y <= 0 || screen.x <= 0 || screen.y <= 0 do return {}, {}
	ratio := [2]f32{screen.x / source.x, screen.y / source.y}
	smaller := min(ratio.x, ratio.y)
	larger := max(ratio.x, ratio.y)

	scale := ratio // STRETCH
	switch fit {
	case .FIT: scale = {smaller, smaller}
	case .FILL: scale = {larger, larger}
	case .STRETCH:
	case .INTEGER:
		// A screen smaller than the picture gets 1, cropped: a scale of 0 would draw nothing
		whole := max(1, f32(int(smaller)))
		scale = {whole, whole}
	}
	size := source * scale
	// The axis that decides the scale is the screen's own size exactly: source * (screen / source) is a hair off in f32
	switch fit {
	case .STRETCH: size = screen
	case .FIT: if ratio.x <= ratio.y do size.x = screen.x; else do size.y = screen.y
	case .FILL: if ratio.x >= ratio.y do size.x = screen.x; else do size.y = screen.y
	case .INTEGER:
	}
	top_left = (screen - size) / 2
	// Whole pixels, so a pixel-perfect picture stays on the pixel grid
	if fit == .INTEGER do top_left = {f32(int(top_left.x)), f32(int(top_left.y))}
	bottom_right = top_left + size
	return
}

/*Where the target's picture lands when drawn by render_upscaled_target, in the screen's pixels (top-left origin, y down)*/
calculate_upscaled_rectangle :: proc(target:Render_Target, fit := Fit_Mode.FIT) -> (min, max:[2]f32) {
	size := get_draw_size()
	return calculate_fit_rectangle({f32(target.width), f32(target.height)}, {f32(size.x), f32(size.y)}, fit)
}

/*
	A window pixel (the mouse, a touch; top-left origin, y down) to a pixel of the target as render_upscaled_target
	draws it. Outside the picture the result is outside 0..size. Take it to world units with
	`calculate_screen_to_world_2d(camera, position, {f32(target.width), f32(target.height)})`
*/
calculate_target_position :: proc(target:Render_Target, window_position:[2]f32, fit := Fit_Mode.FIT) -> [2]f32 {
	screen := get_screen_size()
	return calculate_target_position_in({f32(target.width), f32(target.height)}, {f32(screen.x), f32(screen.y)}, window_position, fit)
}

/*The maths of calculate_target_position, for any picture size and screen size*/
@(private)
calculate_target_position_in :: proc(source, screen, window_position:[2]f32, fit:Fit_Mode) -> [2]f32 {
	top_left, bottom_right := calculate_fit_rectangle(source, screen, fit)
	size := bottom_right - top_left
	if size.x <= 0 || size.y <= 0 do return {}
	return (window_position - top_left) / size * source
}

/*
	Where a pointer is, in the pixels the game draws in: the window's, or the internal resolution's while
	set_internal_resolution is on. The mouse and touch maths read it
*/
@(private)
calculate_pointer_draw_position :: proc(window_position:[2]f32) -> [2]f32 {
	state := &mbi.render_target_state
	if is_internal_resolution_on() == false do return window_position
	size := get_internal_resolution()
	screen := get_screen_size()
	return calculate_target_position_in({f32(size.x), f32(size.y)}, {f32(screen.x), f32(screen.y)}, window_position, state.internal.fit)
}

/*The size pointer positions are measured against: the window, or the internal resolution while it is on*/
@(private)
get_pointer_draw_size :: proc() -> [2]f32 {
	if is_internal_resolution_on() == false {
		size := get_screen_size()
		return {f32(size.x), f32(size.y)}
	}
	size := get_internal_resolution()
	return {f32(size.x), f32(size.y)}
}

/*Makes a target. Nothing is drawn into it until render_target_start. `destroy(&target)` frees it*/
create_render_target :: proc(settings := Render_Target_Settings{}) -> (target:Render_Target) {
	size := calculate_render_target_size(settings.width, settings.height, settings.scale, get_screen_size())
	target.width = size.x
	target.height = size.y
	target.has_depth = settings.no_depth == false

	allocate_render_target(&target, settings.filter)

	meta := default_texture_meta()
	target.texture.width = size.x
	target.texture.height = size.y
	target.texture.filter = settings.filter
	target.texture.pixels_per_unit = meta.pixels_per_unit
	target.texture.columns = meta.columns
	target.texture.rows = meta.rows
	target.texture.frame_count = meta.frame_count
	return
}

/*Frees the target's colour and depth. Not while it is being drawn into; the texture copies are dead too*/
destroy_render_target :: proc(target:^Render_Target) {
	ensure(mbi.render_target_state.is_active == false || mbi.render_target_state.active.texture.texture != target.texture.texture, "A render target is destroyed while it is being drawn into")
	free_render_target(target)
	target^ = {}
}

/*
	Everything drawn until render_target_end goes into `target`: cameras, screen_start, text, as usual, in the
	target's pixels. Clears colour (and depth) to `clear_color`; pass nil to keep what was drawn before.
	Between render_start and render_end, before anything is drawn to the screen, not inside camera_start, not nested
*/
render_target_start :: proc(target:^Render_Target, clear_color:Maybe([4]f32) = [4]f32{0, 0, 0, 0}) {
	state := &mbi.render_target_state
	ensure(mbi.camera_active == false, "render_target_start was called inside camera_start")
	ensure(state.internal_frame == false, "A render target cannot be drawn while set_internal_resolution is on: it already is one")
	ensure(state.is_active == false, "Render targets do not nest")
	ensure(state.screen_drawn == false, "Draw every render target before the screen: something was already drawn to the screen this frame")
	ensure(target.width > 0, "The render target was never created")

	bind_render_target(target, clear_color)
	state.active = target^
	state.is_active = true
}

/*Back to the screen. The target's texture is finished and can be drawn*/
render_target_end :: proc() {
	state := &mbi.render_target_state
	ensure(state.is_active, "render_target_end was called without render_target_start")
	ensure(mbi.camera_active == false, "render_target_end was called before camera_end")

	unbind_render_target(&state.active)
	state.active = {}
	state.is_active = false
}

/*
	Draws the target over the screen in `fit`, as a pass of its own, with no camera needed: between render_start and
	render_end, outside render_target_start. The bars (if any) are left as they are, so clear the screen first
*/
render_upscaled_target :: proc(target:Render_Target, fit := Fit_Mode.FIT, tint := [4]f32{1, 1, 1, 1}, shader := Shader{}) {
	ensure(mbi.camera_active == false, "render_upscaled_target was called inside camera_start")
	ensure(target.width > 0, "The render target was never created")

	min, max := calculate_upscaled_rectangle(target, fit)
	size := get_draw_size()

	// A screen camera as tall as the screen is in pixels: one unit a pixel, y up from the centre
	centre := (min + max) / 2 - {f32(size.x), f32(size.y)} / 2
	camera_start(create_screen_camera(f32(size.y)))
	model := calculate_model_matrix({centre.x, -centre.y, 0}, linalg.QUATERNIONF32_IDENTITY, {max.x - min.x, max.y - min.y, 1})
	queue_render(mbi.sprite_mesh, model, tint, .NONE, .NONE, target.texture, {0, 0, 1, 1}, 0, shader = shader)
	camera_end()
}

/*
	A world camera needs depth, and a screen one does not. Called by each camera_start: drawing a world
	into a target with no depth buffer would draw in submission order without saying so
*/
@(private)
check_camera_destination :: proc(camera:Camera) {
	state := &mbi.render_target_state
	if state.is_active && state.active.has_depth == false {
		ensure(camera.screen == true, "A world camera cannot draw into a render target made with no_depth")
	}
}

/*Says the screen has been drawn to, so a render target can no longer start this frame. Called by each camera_end that draws*/
@(private)
note_screen_drawn :: proc() {
	if mbi.render_target_state.is_active == false do mbi.render_target_state.screen_drawn = true
}

/*
	Draws the whole game at `settings`' size and scales it to the screen: one line to draw fewer pixels
	(the Vita's frame time is its pixel cost). Everything measured in pixels follows: get_window_size is not
	changed, but cameras, anchors and calculate_visible_rectangle answer in internal pixels, and the mouse and
	touch maths unscale through `fit`. Takes effect next frame; the zero value turns it off
	**Measured, not assumed:** on the Vita a smaller picture is a faster frame (its cost is its pixels). On the real New 3DS LL
	the first measurement went the other way (full 21.6 ms, 2/3 and 1/2 size 33.5 ms), because the extra pass, the clear and the
	upscale cost more than the pixels saved; get_gpu_times says how much of a frame is the GPU's. Do not turn this on for the
	3DS's top screen without measuring the game on the console
*/
set_internal_resolution :: proc(settings := Internal_Resolution_Settings{}) {
	ensure(mbi.render_target_state.internal_frame == false, "set_internal_resolution was called between render_start and render_end")
	ensure((settings.width == 0) == (settings.height == 0), "set_internal_resolution needs both a width and a height, or neither")
	mbi.render_target_state.internal = settings
	// Made here, between frames, not in render_start: the 3DS dies (an unexplained svcBreak in Azahar) when a target is
	// created in the middle of a frame. Off, the target is given back
	prepare_internal_target()
}

/*Makes, remakes or frees the internal target to match the settings. Outside a frame*/
@(private)
prepare_internal_target :: proc() {
	state := &mbi.render_target_state
	if is_internal_resolution_on() == false {
		if state.internal_target.width > 0 do destroy_render_target(&state.internal_target)
		return
	}
	size := get_internal_resolution()
	target := &state.internal_target
	if target.width == size.x && target.height == size.y && target.texture.filter == state.internal.filter do return
	if target.width > 0 do destroy_render_target(target)
	target^ = create_render_target({width = size.x, height = size.y, filter = state.internal.filter})
}

@(private)
is_internal_resolution_on :: proc() -> bool {
	settings := mbi.render_target_state.internal
	return settings.width > 0 || settings.height > 0 || settings.scale > 0
}

/*The size the game is drawn at: the internal resolution while it is on, else the screen's*/
get_internal_resolution :: proc() -> [2]i32 {
	settings := mbi.render_target_state.internal
	if is_internal_resolution_on() == false do return get_screen_size()
	return calculate_render_target_size(settings.width, settings.height, settings.scale, get_screen_size())
}

/*Called at the end of render_start: opens the internal target if it is on*/
@(private)
begin_internal_frame :: proc() {
	state := &mbi.render_target_state
	state.screen_drawn = false
	if is_internal_resolution_on() == false do return

	prepare_internal_target() // a no-op unless the screen changed size (a PC window resized)
	target := &state.internal_target
	render_target_start(target, [4]f32{0, 0, 0, 1})
	state.internal_frame = true
}

/*Called at the start of render_end: finishes the internal target and puts it on the screen*/
@(private)
end_internal_frame :: proc() {
	state := &mbi.render_target_state
	if state.internal_frame == false do return
	state.internal_frame = false
	render_target_end()
	// The bars are the only part the picture leaves, so a picture that covers the screen needs no clear (on the 3DS a
	// clear is a synchronous memory fill the CPU waits for)
	top_left, bottom_right := calculate_upscaled_rectangle(state.internal_target, state.internal.fit)
	screen := get_screen_size()
	covers := top_left.x <= 0 && top_left.y <= 0 && bottom_right.x >= f32(screen.x) && bottom_right.y >= f32(screen.y)
	if covers == false do clear_screen([4]f32{0, 0, 0, 1})
	render_upscaled_target(state.internal_target, state.internal.fit)
}
