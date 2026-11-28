#+build windows

package matchbox

/*
	Render targets drawn on a real D3D11 device (the software one, WARP) and read back pixel by pixel.
	The expected colours are chosen so the maths is by hand: channels are 0 or 1 (which sRGB leaves alone), and the
	one grey is checked against the sRGB curve worked out separately (0.5 linear is 188/255)
*/

import "core:math"
import "core:log"
import "core:sync"
import "core:testing"
import "core:time"

import win "core:sys/windows"
import "vendor:directx/d3d11"

// What the test changes in `mbi`, put back afterwards
@(private="file")
Saved_Device :: struct {
	backend:Backend_State,
	opaque_items:[dynamic]Render_Item,
	transparent_items:[dynamic]Render_Item,
	sprite_mesh:Mesh,
	camera_active:bool,
	state:Render_Target_State,
}

@(private="file")
start_device :: proc() -> (saved:Saved_Device, ok:bool) {
	sync.mutex_lock(&render_queue_lock)
	saved = {mbi.backend, mbi.opaque_items, mbi.transparent_items, mbi.sprite_mesh, mbi.camera_active, mbi.render_target_state}

	device:^d3d11.IDevice
	device_context:^d3d11.IDeviceContext
	result := d3d11.CreateDevice(nil, .WARP, nil, {}, nil, 0, d3d11.SDK_VERSION, &device, nil, &device_context)
	if win.SUCCEEDED(result) == false do return saved, false

	mbi.device = device
	mbi.device_context = device_context
	mbi.opaque_items = {}
	mbi.transparent_items = {}
	mbi.framebuffer_view = nil // render_target_end binds the swapchain's, which a test has not got
	mbi.depth_view = nil
	create_pipeline()
	create_white_texture()
	vertices, indices := create_quad_geometry()
	mbi.sprite_mesh = create_mesh(vertices, indices)
	delete(vertices)
	delete(indices)
	return saved, true
}

@(private="file")
stop_device :: proc(saved:Saved_Device) {
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
	sync.mutex_unlock(&render_queue_lock)
}

@(private="file")
read_target :: proc(target:Render_Target) -> []u8 {
	return read_render_target_pixels(target, context.temp_allocator)
}

@(private="file")
pixel_at :: proc(pixels:[]u8, width, x, y:int) -> [4]u8 {
	offset := (y * width + x) * 4
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

@(test)
a_scene_drawn_into_a_target_reads_back_exactly :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return // no software device: nothing to check here

	// 64x32 pixels, a camera 32 units tall: one unit a pixel, x from -32 to 32 and y from 16 to -16
	scene := create_render_target({width = 64, height = 32})
	defer destroy_render_target(&scene)

	render_target_start(&scene, [4]f32{0, 0, 0, 1})
	camera_start(create_camera_2d(32))
	// Four quadrants at the back (z -5), each 32x16 pixels
	render_rectangle({-16, 8, -5}, {32, 16}, {1, 0, 0, 1}) // top left: red
	render_rectangle({16, 8, -5}, {32, 16}, {0, 1, 0, 1}) // top right: green
	render_rectangle({-16, -8, -5}, {32, 16}, {0, 0, 1, 1}) // bottom left: blue
	render_rectangle({16, -8, -5}, {32, 16}, {1, 1, 1, 1}) // bottom right: white
	// Depth decides these two, not the order: the near yellow (z 1) is drawn first, the far magenta (z -1) second.
	// Yellow covers x -4..4, magenta x -2..6, both y -4..4, so x -2..4 is yellow and x 4..6 is magenta
	render_rectangle({0, 0, 1}, {8, 8}, {1, 1, 0, 1})
	render_rectangle({2, 0, -1}, {8, 8}, {1, 0, 1, 1})
	camera_end()
	render_target_end()

	pixels := read_target(scene)
	testing.expect_value(t, pixel_at(pixels, 64, 8, 4), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel_at(pixels, 64, 56, 4), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, pixel_at(pixels, 64, 8, 28), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel_at(pixels, 64, 56, 28), [4]u8{255, 255, 255, 255})
	// Corners: the first and last pixel are the quadrants' own
	testing.expect_value(t, pixel_at(pixels, 64, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel_at(pixels, 64, 63, 31), [4]u8{255, 255, 255, 255})
	// The pair at the middle: pixel (35, 16) is world x 3.5: yellow; pixel (37, 16) is world x 5.5: magenta
	testing.expect_value(t, pixel_at(pixels, 64, 35, 16), [4]u8{255, 255, 0, 255})
	testing.expect_value(t, pixel_at(pixels, 64, 37, 16), [4]u8{255, 0, 255, 255})
	// Pixel (31, 16), world x -0.5: both cover it, and the near one wins: yellow, though magenta was drawn after
	testing.expect_value(t, pixel_at(pixels, 64, 31, 16), [4]u8{255, 255, 0, 255})
}

@(test)
upscaling_by_two_repeats_every_pixel_and_a_grey_survives_the_round_trip :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	small := create_render_target({width = 8, height = 4, no_depth = true})
	defer destroy_render_target(&small)
	render_target_start(&small, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(4)) // one unit a pixel; a screen camera, since this target has no depth
	render_rectangle({-2, 1, 0}, {4, 2}, {1, 0, 0, 1}) // top left quarter
	render_rectangle({2, 1, 0}, {4, 2}, {0.5, 0.5, 0.5, 1}) // top right quarter: mid grey (linear 0.5)
	render_rectangle({-3, -1, 0}, {2, 2}, {0, 0, 1, 1}) // bottom left, the first two columns
	camera_end()
	render_target_end()

	// Into a second target, 16x8: the draw size is the one being drawn into, so INTEGER is exactly x2
	big := create_render_target({width = 16, height = 8, no_depth = true})
	defer destroy_render_target(&big)
	render_target_start(&big, [4]f32{0, 0, 0, 1})
	render_upscaled_target(small, .INTEGER)
	render_target_end()

	source := read_target(small)
	result := read_target(big)
	for y in 0 ..< 8 {
		for x in 0 ..< 16 {
			testing.expect_value(t, pixel_at(result, 16, x, y), pixel_at(source, 8, x / 2, y / 2))
		}
	}
	testing.expect_value(t, pixel_at(source, 8, 1, 1), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel_at(source, 8, 0, 3), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel_at(source, 8, 7, 3), [4]u8{0, 0, 0, 255}) // untouched: the clear colour

	// 0.5 linear is 188 in sRGB (0.5^(1/2.4) * 1.055 - 0.055 = 0.7354 -> 187.5). It went in once and came out once:
	// a target that did not decode on the way back would give 0.7354 encoded again, 225
	grey := pixel_at(result, 16, 12, 2)
	testing.expect(t, int(grey.r) >= 187 && int(grey.r) <= 189, "the grey's red")
	testing.expect_value(t, grey.r, grey.g)
	testing.expect_value(t, grey.g, grey.b)
	testing.expect_value(t, grey, pixel_at(source, 8, 6, 1))
}

@(test)
linear_sampling_blends_where_point_sampling_does_not :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// Two pixels, red then blue, drawn into 8x1 targets of each filter
	for filter in Filter_Mode {
		pair := create_render_target({width = 2, height = 1, no_depth = true, filter = filter})
		render_target_start(&pair, [4]f32{0, 0, 0, 1})
		camera_start(create_screen_camera(1))
		render_rectangle({-0.5, 0, 0}, {1, 1}, {1, 0, 0, 1})
		render_rectangle({0.5, 0, 0}, {1, 1}, {0, 0, 1, 1})
		camera_end()
		render_target_end()

		wide := create_render_target({width = 8, height = 1, no_depth = true})
		render_target_start(&wide, [4]f32{0, 0, 0, 1})
		render_upscaled_target(pair, .STRETCH)
		render_target_end()

		pixels := read_target(wide)
		// Pixel 3 samples u = 3.5 / 8 = 0.4375, texel 0.875: between the two texel centres (0.5 and 1.5), mostly red
		middle := pixel_at(pixels, 8, 3, 0)
		if filter == .POINT {
			testing.expect_value(t, middle, [4]u8{255, 0, 0, 255})
			testing.expect_value(t, pixel_at(pixels, 8, 4, 0), [4]u8{0, 0, 255, 255})
		} else {
			testing.expect(t, middle.r > 0 && middle.b > 0 && middle.r < 255 && middle.b < 255, "a linear upscale blends the two")
			testing.expect(t, middle.r > middle.b, "and is closer to the nearer pixel")
		}
		destroy_render_target(&wide)
		destroy_render_target(&pair)
	}
}

@(test)
a_frame_with_an_internal_resolution_reaches_the_screen_scaled :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// A 16x8 "screen" standing in for the swapchain's buffer
	description := d3d11.TEXTURE2D_DESC {
		Width = 16, Height = 8, MipLevels = 1, ArraySize = 1,
		Format = .R8G8B8A8_UNORM_SRGB,
		SampleDesc = {Count = 1},
		Usage = .DEFAULT,
		BindFlags = {.RENDER_TARGET},
	}
	screen:^d3d11.ITexture2D
	mbi.device->CreateTexture2D(&description, nil, &screen)
	defer screen->Release()
	mbi.device->CreateRenderTargetView(screen, nil, &mbi.framebuffer_view)
	defer mbi.framebuffer_view->Release()

	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_window := mbi.window_size
	defer mbi.window_size = saved_window
	mbi.window_size = {16, 8, 0, 0}

	// 8x4 internal, scaled x2 to fill the screen exactly
	set_internal_resolution({width = 8, height = 4, fit = .INTEGER})
	begin_internal_frame()
	testing.expect_value(t, get_draw_size(), [2]i32{8, 4})
	camera_start(create_screen_camera(4)) // a unit an internal pixel
	render_rectangle({-2, 1, 0}, {4, 2}, {1, 0, 0, 1}) // the top left quarter, red
	camera_end()
	end_internal_frame()
	testing.expect_value(t, mbi.render_target_state.is_active, false)

	pixels := read_target(Render_Target{texture = {texture = screen}, width = 16, height = 8})
	testing.expect_value(t, pixel_at(pixels, 16, 0, 0), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, pixel_at(pixels, 16, 7, 3), [4]u8{255, 0, 0, 255}) // the last pixel of the red quarter
	testing.expect_value(t, pixel_at(pixels, 16, 8, 0), [4]u8{0, 0, 0, 255}) // beside it: the clear colour
	testing.expect_value(t, pixel_at(pixels, 16, 0, 4), [4]u8{0, 0, 0, 255})

	destroy_render_target(&mbi.render_target_state.internal_target)
	set_internal_resolution({})
}

@(test)
resizing_a_target_between_frames_keeps_it_drawable_and_costs_little :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	target := create_render_target({width = 64, height = 48, filter = .LINEAR})
	defer destroy_render_target(&target)

	testing.expect(t, resize_render_target(&target, 64, 48) == false, "the same size should do nothing")

	// A splitter being dragged: a new size every frame, drawn into each time and read back so the GPU has to finish
	started := time.now()
	FRAMES :: 120
	for frame in 0 ..< FRAMES {
		width := i32(65 + frame % 40)
		height := i32(48 + frame % 24)
		testing.expect(t, resize_render_target(&target, width, height), "a new size should resize")
		testing.expect_value(t, target.width, width)
		testing.expect_value(t, target.height, height)
		testing.expect_value(t, target.texture.filter, Filter_Mode.LINEAR) // kept across the resize

		render_target_start(&target, [4]f32{0, 0, 1, 1})
		camera_start(create_screen_camera(f32(height)))
		render_rectangle({0, 0, 0}, {4, 4}, {1, 0, 0, 1})
		camera_end()
		render_target_end()

		pixels := read_render_target_pixels(target, context.temp_allocator)
		middle := (int(height / 2) * int(width) + int(width / 2)) * 4
		if frame == FRAMES - 1 do testing.expect_value(t, [4]u8{pixels[middle], pixels[middle + 1], pixels[middle + 2], pixels[middle + 3]}, [4]u8{255, 0, 0, 255})
		free_all(context.temp_allocator)
	}
	per_frame := time.duration_milliseconds(time.since(started)) / FRAMES
	// Not an assertion on speed (a software device's numbers are not a GPU's): the figure goes in the plan, and a generous bound
	// only catches something gone badly wrong
	log.infof("resize + draw + read back: %.3f ms a frame on the software device", per_frame)
	testing.expect(t, per_frame < 50, "resizing a small target every frame should be cheap")
}

@(test)
the_window_screenshot_is_red_first_and_the_right_size :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// A 4x2 stand-in for the swapchain's buffer, blue first like the real one, cleared to orange
	description := d3d11.TEXTURE2D_DESC {
		Width = 4, Height = 2, MipLevels = 1, ArraySize = 1,
		Format = .B8G8R8A8_UNORM,
		SampleDesc = {Count = 1},
		Usage = .DEFAULT,
		BindFlags = {.RENDER_TARGET},
	}
	screen:^d3d11.ITexture2D
	mbi.device->CreateTexture2D(&description, nil, &screen)
	defer screen->Release()
	view:^d3d11.IRenderTargetView
	mbi.device->CreateRenderTargetView(screen, nil, &view)
	defer view->Release()
	orange := [4]f32{1, 0.5, 0, 1}
	mbi.device_context->ClearRenderTargetView(view, &orange)

	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_framebuffer := mbi.framebuffer
	defer mbi.framebuffer = saved_framebuffer
	mbi.framebuffer = screen

	pixels, size := read_window_pixels(context.temp_allocator)
	testing.expect_value(t, size, [2]i32{4, 2})
	testing.expect_value(t, len(pixels), 4 * 2 * 4)
	testing.expect_value(t, pixel_at(pixels, 4, 3, 1), [4]u8{255, 128, 0, 255}) // red first, not blue first
}

@(test)
the_minimum_window_size_is_grown_by_the_frame :: proc(t:^testing.T) {
	// A drawing area of 640x400 needs a window bigger than that by its borders and title bar, and by the same amount for any area
	style := i32(win.WS_OVERLAPPEDWINDOW)
	small := calculate_minimum_tracking_size({640, 400}, style)
	large := calculate_minimum_tracking_size({1280, 800}, style)
	testing.expect(t, small.x > 640 && small.y > 400)
	testing.expect_value(t, large.x - small.x, i32(640))
	testing.expect_value(t, large.y - small.y, i32(400))
}

// How many pixels of a picture are neither the black behind nor the white drawn: the ones an edge only half covers
count_blended_pixels :: proc(pixels:[]u8) -> int {
	count := 0
	for index := 0; index < len(pixels); index += 4 {
		if pixels[index] != 0 && pixels[index] != 255 do count += 1
	}
	return count
}

@(test)
a_multisampled_target_smooths_a_slanted_edge_and_a_plain_one_does_not :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	blended:[2]int
	for samples, index in ([2]i32{1, 4}) {
		target := create_render_target({width = 32, height = 32, samples = samples})
		defer destroy_render_target(&target)
		if samples == 4 do testing.expect(t, target.samples > 1, "WARP should do at least 2 samples")

		render_target_start(&target, [4]f32{0, 0, 0, 1})
		camera_start(create_screen_camera(32))
		render_line({-12, -12, 0}, {12, 12, 0}, 6, {1, 1, 1, 1}) // a thick diagonal: two slanted edges
		camera_end()
		render_target_end()

		pixels := read_render_target_pixels(target, context.temp_allocator)
		blended[index] = count_blended_pixels(pixels)
		testing.expect_value(t, pixel_at(pixels, 32, 16, 16), [4]u8{255, 255, 255, 255}) // the middle of the line
		testing.expect_value(t, pixel_at(pixels, 32, 28, 3), [4]u8{0, 0, 0, 255}) // far from it
		free_all(context.temp_allocator)
	}
	testing.expect_value(t, blended[0], 0)
	testing.expect(t, blended[1] >= 20, "two slanted edges 34 pixels long should leave many half-covered pixels")

	// A resize keeps the sample count, and the new size is drawable
	target := create_render_target({width = 32, height = 32, samples = 4})
	defer destroy_render_target(&target)
	counted := target.samples
	testing.expect(t, resize_render_target(&target, 40, 24))
	testing.expect_value(t, target.samples, counted)
	render_target_start(&target, [4]f32{1, 0, 0, 1})
	render_target_end()
	pixels := read_render_target_pixels(target, context.temp_allocator)
	testing.expect_value(t, pixel_at(pixels, 40, 39, 23), [4]u8{255, 0, 0, 255})
}

// A lit white plane filling a small target, lit by the ambient alone (no lights), read back as its middle pixel
read_lit_plane :: proc(t:^testing.T, settings:Lighting_Settings) -> [4]u8 {
	target := create_render_target({width = 8, height = 8})
	defer destroy_render_target(&target)
	vertices, indices := create_plane_geometry(40, context.temp_allocator)
	plane := create_lit_mesh(vertices, indices)
	defer destroy_mesh(plane)

	set_lights({})
	set_lighting(settings)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_camera_3d({0, 3, 0.001}, {0, 0, 0}, 50)) // looking straight down at a plane whose normal is up: facing the eye
	render_mesh(plane)
	camera_end()
	render_target_end()
	pixels := read_render_target_pixels(target, context.temp_allocator)
	return pixel_at(pixels, 8, 4, 4)
}

@(test)
a_lit_model_gets_the_scenes_exposure_tonemap_fog_and_hemisphere :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_lighting := mbi.lighting
	defer mbi.lighting = saved_lighting

	// Linear colour is encoded to sRGB on the way into the target: 0.5 is 188, 0.75 is 224, 1 is 255
	half := Lighting_Settings{enabled = true, ambient = {0.5, 0.5, 0.5, 1}}
	testing.expect_value(t, read_lit_plane(t, half), [4]u8{188, 188, 188, 255})

	// exposure 2 turns that half into a whole; 0.5 stays what it was when exposure is left at its zero
	doubled := half
	doubled.exposure = 2
	testing.expect_value(t, read_lit_plane(t, doubled), [4]u8{255, 255, 255, 255})

	// an ambient of 3 is clamped to 1 with no tonemap, and brought to 3 / 4 by Reinhard (0.75 in linear light is 225 once sRGB-encoded)
	bright := Lighting_Settings{enabled = true, ambient = {3, 3, 3, 1}}
	testing.expect_value(t, read_lit_plane(t, bright), [4]u8{255, 255, 255, 255})
	bright.tonemap = .REINHARD
	testing.expect_value(t, read_lit_plane(t, bright), [4]u8{225, 225, 225, 255})

	// fog that is complete at once replaces the surface with its own colour
	fogged := half
	fogged.fog = {enabled = true, color = {0, 0, 1, 1}, start = 0, end = 0.001}
	testing.expect_value(t, read_lit_plane(t, fogged), [4]u8{0, 0, 255, 255})

	// a hemisphere: this plane faces up, so it gets the sky's colour and none of the ground's
	hemisphere := Lighting_Settings{enabled = true, ambient = {1, 0, 0, 1}, hemisphere = true, ambient_ground = {0, 0, 1, 1}}
	testing.expect_value(t, read_lit_plane(t, hemisphere), [4]u8{255, 0, 0, 255})
}

@(test)
an_area_light_lights_what_is_in_front_of_it_and_not_what_is_behind :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_lighting := mbi.lighting
	defer mbi.lighting = saved_lighting

	// A unit disk 2 above the floor's middle, shining down: the nearest point to the middle is the disk's centre, 2 away
	fade := 1 / (1 + 2 * (0.09 + 0.032 * 2.0))
	want := math.pow(f32(fade), 1 / 2.4) * 1.055 - 0.055 // linear to sRGB, which the target encodes on the way in
	below := create_area_disk_light({0, 2, 0}, {0, -1, 0}, 1)
	below.specular = {} // the diffuse alone: a highlight straight under a light would saturate
	set_lights({below})
	set_lighting({enabled = true})
	target := create_render_target({width = 8, height = 8})
	defer destroy_render_target(&target)
	vertices, indices := create_plane_geometry(40, context.temp_allocator)
	plane := create_lit_mesh(vertices, indices)
	defer destroy_mesh(plane)

	draw :: proc(target:^Render_Target, plane:Mesh) -> [4]u8 {
		render_target_start(target, [4]f32{0, 0, 0, 1})
		camera_start(create_camera_3d({0, 3, 0.001}, {0, 0, 0}, 50))
		render_mesh(plane)
		camera_end()
		render_target_end()
		return pixel_at(read_render_target_pixels(target^, context.temp_allocator), 8, 4, 4)
	}

	lit := draw(&target, plane)
	testing.expectf(t, abs(f32(lit.x) - want * 255) <= 3, "lit from in front: %v, wanted about %v", lit.x, want * 255)

	// the same light turned to face up shines away from the floor: black
	set_lights({create_area_disk_light({0, 2, 0}, {0, 1, 0}, 1)})
	testing.expect_value(t, draw(&target, plane), [4]u8{0, 0, 0, 255})
}
