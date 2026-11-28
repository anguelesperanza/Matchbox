#+build windows

package matchbox

/*
	The screen pass (the HUD): the order things are painted in, and what a clip does to them. Drawn on a real D3D11 device
	(the software one, WARP) into a render target and read back pixel by pixel, one unit a pixel so the numbers are by hand.
	Colours are 0, 1 or a half, which sRGB leaves alone at 0 and 1; a see-through black over white is 0.5 linear, 188 in sRGB
*/

import "core:sync"
import "core:testing"

import win "core:sys/windows"
import "vendor:directx/d3d11"

@(private = "file")
Saved_Device :: struct {
	backend:           Backend_State,
	opaque_items:      [dynamic]Render_Item,
	transparent_items: [dynamic]Render_Item,
	sprite_mesh:       Mesh,
	camera_active:     bool,
	state:             Render_Target_State,
	clip:              Clip_State,
}

@(private = "file")
start_device :: proc() -> (saved: Saved_Device, ok: bool) {
	sync.mutex_lock(&render_queue_lock)
	saved = {mbi.backend, mbi.opaque_items, mbi.transparent_items, mbi.sprite_mesh, mbi.camera_active, mbi.render_target_state, mbi.clip}

	device: ^d3d11.IDevice
	device_context: ^d3d11.IDeviceContext
	result := d3d11.CreateDevice(nil, .WARP, nil, {}, nil, 0, d3d11.SDK_VERSION, &device, nil, &device_context)
	if win.SUCCEEDED(result) == false do return saved, false

	mbi.device = device
	mbi.device_context = device_context
	mbi.opaque_items = {}
	mbi.transparent_items = {}
	mbi.clip = {}
	mbi.framebuffer_view = nil
	mbi.depth_view = nil
	create_pipeline()
	create_white_texture()
	vertices, indices := create_quad_geometry()
	mbi.sprite_mesh = create_mesh(vertices, indices)
	delete(vertices)
	delete(indices)
	return saved, true
}

@(private = "file")
stop_device :: proc(saved: Saved_Device) {
	if mbi.device != nil {
		device := mbi.device
		device_context := mbi.device_context
		destroy_mesh(mbi.sprite_mesh)
		mbi.white_texture_view->Release()
		mbi.white_texture->Release()
		destroy_pipeline()
		device_context->Release()
		device->Release()
	}
	mbi.backend = saved.backend
	mbi.opaque_items = saved.opaque_items
	mbi.transparent_items = saved.transparent_items
	mbi.sprite_mesh = saved.sprite_mesh
	mbi.camera_active = saved.camera_active
	mbi.render_target_state = saved.state
	mbi.clip = saved.clip
	sync.mutex_unlock(&render_queue_lock)
}

@(private = "file")
pixel_at :: proc(pixels: []u8, width, x, y: int) -> [4]u8 {
	offset := (y * width + x) * 4
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

// A 16x16 target drawn through a screen camera 16 units tall: one unit a pixel, x and y from -8 to 8, +Y up, origin at the
// centre, so pixel (px, py) is the unit square whose lower left corner is (px - 8, 7 - py)
@(private = "file")
SIZE :: 16

@(private = "file")
RED :: [4]f32{1, 0, 0, 1}
@(private = "file")
WHITE_OPAQUE :: [4]f32{1, 1, 1, 1}

@(test)
a_solid_panel_drawn_after_a_dim_covers_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = SIZE, height = SIZE, no_depth = true})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	// A modal: a see-through dim over the whole window, then a solid panel in the middle. Submission order is paint order, so
	// the panel is on top of the dim, and the dim only darkens what is outside the panel
	render_rectangle({0, 0, 0}, {SIZE, SIZE}, WHITE_OPAQUE)
	render_rectangle({0, 0, 0}, {SIZE, SIZE}, {0, 0, 0, 0.5})
	render_rectangle({0, 0, 0}, {6, 6}, RED)
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target, context.temp_allocator)
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 8), [4]u8{255, 0, 0, 255}) // the panel, untouched by the dim
	outside := pixel_at(pixels, SIZE, 1, 1)
	testing.expect(t, outside.r > 150 && outside.r < 220 && outside.r == outside.g, "the dim should darken white to a grey")
}

@(test)
a_see_through_hover_drawn_after_solid_rows_lies_over_them :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = SIZE, height = SIZE, no_depth = true})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	// A dropdown: solid rows, then a see-through hover highlight over one of them. Opaque-then-see-through already worked,
	// and must go on working
	render_rectangle({0, 0, 0}, {SIZE, SIZE}, WHITE_OPAQUE)
	render_rectangle({0, 0, 0}, {6, 6}, {1, 0, 0, 0.5})
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target, context.temp_allocator)
	over := pixel_at(pixels, SIZE, 8, 8)
	testing.expect_value(t, over.r, 255)
	testing.expect(t, over.g > 150 && over.g < 220, "white under a half red is pink: green and blue lowered")
	testing.expect_value(t, pixel_at(pixels, SIZE, 1, 1), [4]u8{255, 255, 255, 255})
}

@(test)
z_is_still_the_layer_and_equal_z_keeps_submission_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = SIZE, height = SIZE, no_depth = true})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	// Submitted green first, then red, but green is nearer (a higher z), so it lands on top of red where they overlap:
	// red covers x -4..2, green x -2..4
	render_rectangle({-1, 0, 0}, {6, 4}, {0, 1, 0, 1}) // z 0
	render_rectangle({-1, 0, -1}, {6, 4}, {1, 0, 0, 1}) // z -1, behind, though submitted second
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target, context.temp_allocator)
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 8), [4]u8{0, 255, 0, 255})
}

@(test)
a_clip_hides_what_lies_outside_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = SIZE, height = SIZE, no_depth = true})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	// A list taller than its box: the red row is drawn across the whole window, but only x -4..4, y -2..2 may show
	clip_start({-4, -2}, {4, 2})
	render_rectangle({0, 0, 0}, {SIZE, SIZE}, RED)
	clip_end()
	// And what comes after the clip is not clipped
	render_rectangle({6, 6, 0}, {2, 2}, {0, 1, 0, 1})
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target, context.temp_allocator)
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 8), [4]u8{255, 0, 0, 255}) // inside
	testing.expect_value(t, pixel_at(pixels, SIZE, 4, 8), [4]u8{255, 0, 0, 255}) // x -4 is the first pixel in
	testing.expect_value(t, pixel_at(pixels, SIZE, 3, 8), [4]u8{0, 0, 0, 255}) // one pixel left of the clip
	testing.expect_value(t, pixel_at(pixels, SIZE, 11, 8), [4]u8{255, 0, 0, 255}) // x 3..4 is the last pixel in
	testing.expect_value(t, pixel_at(pixels, SIZE, 12, 8), [4]u8{0, 0, 0, 255}) // x 4..5 is out
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 6), [4]u8{255, 0, 0, 255}) // y 1..2 is the top row in
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 5), [4]u8{0, 0, 0, 255}) // y 2..3 is above the clip
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 9), [4]u8{255, 0, 0, 255}) // y -2..-1 is the last row in
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 10), [4]u8{0, 0, 0, 255}) // y -3..-2 is below it
	testing.expect_value(t, pixel_at(pixels, SIZE, 14, 1), [4]u8{0, 255, 0, 255}) // drawn after clip_end, in the corner
}

@(test)
a_clip_inside_a_clip_keeps_only_the_shared_area :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = SIZE, height = SIZE, no_depth = true})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	// The outer clip is x -4..2; the inner one asks for x -2..6 and is cut to -2..2, so a dropdown cannot leave its list
	clip_start({-4, -4}, {2, 4})
	clip_start({-2, -4}, {6, 4})
	render_rectangle({0, 0, 0}, {SIZE, SIZE}, RED)
	min, max, active := get_clip_rectangle()
	testing.expect_value(t, min, [2]f32{-2, -4})
	testing.expect_value(t, max, [2]f32{2, 4})
	testing.expect(t, active)
	clip_end()
	// Back to the outer clip alone
	// Green, one layer behind the red, so red stays on top where both are
	render_rectangle({0, 0, -1}, {SIZE, SIZE}, {0, 1, 0, 1})
	clip_end()
	_, _, still := get_clip_rectangle()
	testing.expect(t, still == false)
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target, context.temp_allocator)
	testing.expect_value(t, pixel_at(pixels, SIZE, 8, 8), [4]u8{255, 0, 0, 255}) // red, cut to x -2..2, over the green
	testing.expect_value(t, pixel_at(pixels, SIZE, 5, 8), [4]u8{0, 255, 0, 255}) // x -3 is in the outer clip only
	testing.expect_value(t, pixel_at(pixels, SIZE, 12, 8), [4]u8{0, 0, 0, 255}) // x 4 is in neither
	testing.expect_value(t, pixel_at(pixels, SIZE, 3, 8), [4]u8{0, 0, 0, 255}) // x -5 is in neither
}

@(test)
two_clips_that_share_nothing_draw_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = SIZE, height = SIZE, no_depth = true})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	clip_start({-6, -6}, {-2, 6})
	clip_start({2, -6}, {6, 6})
	render_rectangle({0, 0, 0}, {SIZE, SIZE}, RED)
	clip_end()
	clip_end()
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target, context.temp_allocator)
	for index in 0 ..< SIZE * SIZE {
		testing.expect_value(t, pixels[index * 4], 0)
	}
}

@(test)
a_one_pixel_rectangle_is_one_crisp_pixel_at_odd_and_even_heights :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// Measured for Stargate's worry that an odd window height blurs a 1-unit line: shapes are untextured quads with no
	// multisampling, so a pixel is lit or it is not, and the line is one row whatever the height's parity
	for height in ([?]i32{64, 65, 99, 100}) {
		target := create_render_target({width = 64, height = height, no_depth = true})
		defer destroy_render_target(&target)
		render_target_start(&target, [4]f32{0, 0, 0, 1})
		camera_start(create_screen_camera(12))
		pixel := 12 / f32(height) // one pixel in units
		render_rectangle({0, 2.3, 0}, {3, pixel}, WHITE_OPAQUE)
		camera_end()
		render_target_end()

		pixels := read_render_target_pixels(target, context.temp_allocator)
		lit, partial := 0, 0
		for y in 0 ..< int(height) {
			value := pixel_at(pixels, 64, 32, y).r
			if value > 0 do lit += 1
			if value > 0 && value < 255 do partial += 1
		}
		testing.expectf(t, lit == 1 && partial == 0, "height %v: %v rows lit, %v of them part-lit", height, lit, partial)
	}
}
