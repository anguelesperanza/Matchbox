#+build windows

package matchbox

/*
	Game shaders on a real D3D11 device (the software one, WARP): drawn into a render target and read back pixel by pixel.
	testdata/shaders/solid.mbs paints every pixel with its `paint` uniform, so a pixel says which shader drew it and
	whether set_shader_value reached it
*/

import "core:math"
import "core:math/linalg"
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
	shader_state:      Shader_State,
	asset_path:        string,
	target_asset_path: string,
}

@(private = "file")
start_device :: proc(assets := TEST_ASSETS) -> (saved: Saved_Device, ok: bool) {
	sync.mutex_lock(&render_queue_lock)
	saved = {mbi.backend, mbi.opaque_items, mbi.transparent_items, mbi.sprite_mesh, mbi.camera_active, mbi.render_target_state, mbi.shader_state, mbi.asset_path, mbi.target_asset_path}

	device: ^d3d11.IDevice
	device_context: ^d3d11.IDeviceContext
	result := d3d11.CreateDevice(nil, .WARP, nil, {}, nil, 0, d3d11.SDK_VERSION, &device, nil, &device_context)
	if win.SUCCEEDED(result) == false do return saved, false

	mbi.device = device
	mbi.device_context = device_context
	mbi.opaque_items = {}
	mbi.transparent_items = {}
	mbi.framebuffer_view = nil
	mbi.depth_view = nil
	mbi.shader_state = {}
	mbi.target_asset_path = ""
	mbi.asset_path = assets
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
	mbi.shader_state = saved.shader_state
	mbi.asset_path = saved.asset_path
	mbi.target_asset_path = saved.target_asset_path
	sync.mutex_unlock(&render_queue_lock)
}

// find_asset adds "shaders/" to these
@(private = "file")
TEST_ASSETS :: #directory + "testdata/"

// Where Matchbox keeps the shaders a game copies into its own assets (optional/shaders/): read in place here
@(private = "file")
OPTIONAL_ASSETS :: #directory + "optional/"

@(private = "file")
SIZE :: 16

// One quad covering the whole target, drawn the way render_upscaled_target draws the picture, then the middle pixel
@(private = "file")
draw_cover :: proc(shader: Shader, use_state: bool) -> [4]u8 {
	target := create_render_target({width = SIZE, height = SIZE})
	defer destroy_render_target(&target)

	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_screen_camera(SIZE))
	model := calculate_model_matrix({0, 0, 0}, linalg.QUATERNIONF32_IDENTITY, {SIZE, SIZE, 1})
	if use_state {
		set_shader(shader)
		queue_render(mbi.sprite_mesh, model, {1, 1, 1, 1}, .NONE, .NONE, {}, {0, 0, 1, 1}, 0)
	} else {
		queue_render(mbi.sprite_mesh, model, {1, 1, 1, 1}, .NONE, .NONE, {}, {0, 0, 1, 1}, 0, shader = shader)
	}
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target)
	defer delete(pixels)
	offset := (SIZE / 2 * SIZE + SIZE / 2) * 4
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

@(test)
a_shader_the_game_loads_draws_and_takes_its_uniforms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	shader, loaded := load_shader_checked("solid")
	testing.expect(t, loaded, "testdata/shaders/solid.pc.hlsl should load")
	if loaded == false do return
	defer destroy_shader(shader)

	// Before any uniform is set the block is zeros: black, not whatever the last draw left
	testing.expect_value(t, draw_cover(shader, true), [4]u8{0, 0, 0, 0})

	set_shader_value("paint", [4]f32{0, 1, 0, 1}, shader)
	testing.expect_value(t, draw_cover(shader, true), [4]u8{0, 255, 0, 255})

	// A second write reaches the next draw, so the value is not just the first one cached
	set_shader_value("paint", [4]f32{1, 0, 0, 1}, shader)
	testing.expect_value(t, draw_cover(shader, true), [4]u8{255, 0, 0, 255})

	// Back to the built-in: the plain white texture times the white tint
	testing.expect_value(t, draw_cover({}, true), [4]u8{255, 255, 255, 255})
}

@(test)
a_shader_given_to_one_draw_does_not_change_the_state :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	shader, loaded := load_shader_checked("solid")
	if loaded == false do return
	defer destroy_shader(shader)
	set_shader_value("paint", [4]f32{0, 0, 1, 1}, shader)

	// The state is the built-in, so only the queued item carries the shader: this is how render_upscaled_target hands one over
	testing.expect_value(t, draw_cover(shader, false), [4]u8{0, 0, 255, 255})
	testing.expect(t, mbi.shader_state.current.data == nil, "queue_render with a shader must not set the state")
}

@(test)
a_game_shader_does_not_touch_the_built_ins_uniforms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	shader, loaded := load_shader_checked("solid")
	if loaded == false do return
	defer destroy_shader(shader)

	// mesh.mbs declares no game uniform, so a name that only the game shader has is refused for the built-in. Its message
	// is what write_shader_value says, which the reflection tests cover; here the two blocks must be separate
	testing.expect(t, mbi.game_constants == nil, "mesh.mbs has no game block, so a game shader's is not the built-in's")
	data := (^Shader_Data)(shader.data)
	testing.expect(t, data.game_constants != nil, "solid.mbs declares `paint`, so its block exists")
	testing.expect_value(t, len(data.game_shadow), 16)
}

@(test)
a_missing_shader_is_not_loaded_and_says_so :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	_, loaded := load_shader_checked("no_such_shader")
	testing.expect(t, loaded == false, "a shader that is not in the assets must come back not loaded")
}

@(test)
the_pipeline_that_draws_a_mesh_follows_what_the_shader_has :: proc(t: ^testing.T) {
	// No GPU: the choice is made from what the shader declared and what the mesh is
	plain_mesh := Mesh{}
	lit_mesh := Mesh{lit = true}
	skinned_mesh := Mesh{lit = true, skinned = true}

	flat := Shader_Data{has_plain = true}
	flat_shader := Shader{data = &flat}
	testing.expect(t, choose_shader({mesh = plain_mesh, shader = flat_shader}) == &flat, "a plain shader draws a plain mesh")
	testing.expect(t, choose_shader({mesh = lit_mesh, shader = flat_shader}) == &flat, "a plain shader draws a lit mesh")
	testing.expect(t, choose_shader({mesh = skinned_mesh, shader = flat_shader}) == nil, "no skinned variant: the built-in draws a skinned mesh")

	needs_normal := Shader_Data{has_plain = true, reads_normal = true, has_skinned = true}
	normal_shader := Shader{data = &needs_normal}
	testing.expect(t, choose_shader({mesh = plain_mesh, shader = normal_shader}) == nil, "a shader that reads the normal cannot draw a mesh with none")
	testing.expect(t, choose_shader({mesh = lit_mesh, shader = normal_shader}) == &needs_normal, "it draws a lit one")
	testing.expect(t, choose_shader({mesh = skinned_mesh, shader = normal_shader}) == &needs_normal, "and a skinned one, since it has a variant")

	testing.expect(t, choose_shader({mesh = lit_mesh}) == nil, "no shader set: the built-in")
}

@(test)
the_queue_groups_items_by_shader_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&render_queue_lock)
	defer sync.mutex_unlock(&render_queue_lock)

	saved_items := mbi.opaque_items
	saved_transparent := mbi.transparent_items
	saved_screen := mbi.screen_pass
	defer {
		mbi.opaque_items = saved_items
		mbi.transparent_items = saved_transparent
		mbi.screen_pass = saved_screen
	}
	mbi.opaque_items = make([dynamic]Render_Item, context.temp_allocator)
	mbi.transparent_items = make([dynamic]Render_Item, context.temp_allocator)
	mbi.screen_pass = false

	// Two shaders that are only identities here; nothing dereferences them. Submitted as built-in, shader, built-in,
	// shader: a texture or mesh difference must not pull the two groups apart
	high := Shader{data = rawptr(uintptr(0x1000))}
	append(&mbi.opaque_items, Render_Item{shader = high}, Render_Item{}, Render_Item{shader = high}, Render_Item{})
	sort_render_queue()
	changes := 0
	for index in 1 ..< len(mbi.opaque_items) {
		if mbi.opaque_items[index].shader.data != mbi.opaque_items[index - 1].shader.data do changes += 1
	}
	testing.expect_value(t, changes, 1)
}

@(test)
the_sky_and_game_shaders_cost_nothing_until_a_game_asks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// Startup made the five built-in pipelines and nothing else: no sky shaders, no current game shader
	testing.expect(t, mbi.skybox.constants == nil, "the sky's shaders are compiled by the first sky, not at startup")
	testing.expect(t, mbi.skybox.cubemap_shader == nil && mbi.skybox.panorama_shader == nil)
	testing.expect(t, mbi.shader_state.current.data == nil)

	faces: [6][16][4]u8
	pointers: [6]rawptr
	for &face, index in faces do pointers[index] = &face
	sky := create_skybox_cubemap(pointers, 4)
	defer destroy_skybox(sky)
	testing.expect(t, mbi.skybox.constants != nil && mbi.skybox.cubemap_shader != nil, "the first sky makes them")
}

// ---------------------------------------------------------------------------
// The PSX shaders (optional/shaders/)
// ---------------------------------------------------------------------------

@(private = "file")
read_pixel :: proc(pixels: []u8, x, y: int) -> [4]u8 {
	offset := (y * SIZE + x) * 4
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

// How far a pixel is from what was worked out by hand, per channel: the target stores 8 bits and rounds
@(private = "file")
is_near :: proc(got, want: [4]u8, tolerance: int) -> bool {
	for channel in 0 ..< 4 {
		if abs(int(got[channel]) - int(want[channel])) > tolerance do return false
	}
	return true
}

@(test)
the_psx_picture_filter_dithers_reduces_colour_and_draws_scanlines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device(OPTIONAL_ASSETS)
	defer stop_device(saved)
	if ok == false do return

	post, loaded := load_shader_checked("psx_post")
	testing.expect(t, loaded, "optional/shaders/psx_post.pc.hlsl should load")
	if loaded == false do return
	defer destroy_shader(post)

	// A flat mid grey, 128 / 255, in a target 16 pixels wide, sampled on a grid of 4 cells: each cell is 4 x 4 pixels
	source := create_render_target({width = SIZE, height = SIZE})
	defer destroy_render_target(&source)
	render_target_start(&source, [4]f32{128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0, 1})
	render_target_end()

	destination := create_render_target({width = SIZE, height = SIZE})
	defer destroy_render_target(&destination)
	set_shader_value("grid", [2]f32{4, 4}, post)
	render_target_start(&destination, [4]f32{1, 0, 1, 1})
	camera_start(create_screen_camera(SIZE))
	model := calculate_model_matrix({0, 0, 0}, linalg.QUATERNIONF32_IDENTITY, {SIZE, SIZE, 1})
	queue_render(mbi.sprite_mesh, model, {1, 1, 1, 1}, .NONE, .NONE, source.texture, {0, 0, 1, 1}, 0, shader = post)
	camera_end()
	render_target_end()
	pixels := read_render_target_pixels(destination)
	defer delete(pixels)

	// Worked by hand from the shader's own steps, for 0.502 grey. dither = bayer(x, y) / 16 - 0.5, then + dither * 2/31,
	// then rounded to five bits (n / 31), then darkened by 12% on every odd cell row:
	//   cell (0,0): bayer 0   -> 0.4697 -> 15/31 = 0.4839
	//   cell (1,0): bayer 8   -> 0.5020 -> 16/31 = 0.5161
	//   cell (0,1): bayer 12, odd row -> 0.5181 -> 16/31 * 0.88 = 0.4542
	//   cell (1,1): bayer 4 (-0.25), odd row -> 0.4859 -> 15/31 * 0.88 = 0.4258
	// The shader works in linear light and the target is sRGB, so what is read back is the encoded value (the clear colour
	// went in as 0.502 linear for the same reason). The encode is the sRGB standard's, written here rather than borrowed
	encode :: proc(linear: f32) -> u8 {
		encoded := 12.92 * linear if linear <= 0.0031308 else 1.055 * math.pow(linear, 1.0 / 2.4) - 0.055
		return u8(encoded * 255 + 0.5)
	}
	cases := [?]struct {
		x, y:   int,
		linear: f32,
	}{{1, 1, 15.0 / 31}, {5, 1, 16.0 / 31}, {1, 5, 16.0 / 31 * 0.88}, {5, 5, 15.0 / 31 * 0.88}}
	for entry in cases {
		want := encode(entry.linear)
		testing.expectf(t, is_near(read_pixel(pixels, entry.x, entry.y), {want, want, want, 255}, 1), "pixel (%d, %d): got %v, want %d", entry.x, entry.y, read_pixel(pixels, entry.x, entry.y), want)
	}

	// The pixels inside a cell are the same: it is coarse pixels, not a smooth gradient
	testing.expect_value(t, read_pixel(pixels, 0, 0), read_pixel(pixels, 3, 3))
}

// A lit quad, `size` on a side, facing the camera
@(private = "file")
create_lit_quad :: proc(size: [2]f32) -> Mesh {
	half := size / 2
	white := [4]f32{1, 1, 1, 1}
	vertices := [4]Lit_Vertex {
		{vertex = {position = {-half.x, -half.y, 0}, uv = {0, 1}, color = white}, normal = {0, 0, 1}},
		{vertex = {position = {half.x, -half.y, 0}, uv = {1, 1}, color = white}, normal = {0, 0, 1}},
		{vertex = {position = {half.x, half.y, 0}, uv = {1, 0}, color = white}, normal = {0, 0, 1}},
		{vertex = {position = {-half.x, half.y, 0}, uv = {0, 0}, color = white}, normal = {0, 0, 1}},
	}
	indices := [6]u16{0, 1, 2, 0, 2, 3}
	return create_lit_mesh(vertices[:], indices[:])
}

// The middle pixel of a lit quad drawn with `shader` and the grid set, on a blue background. Lighting is off, so the lit
// shader paints the surface black: black is the quad, blue is the background
@(private = "file")
draw_lit_quad :: proc(shader: Shader, size: [2]f32) -> [4]u8 {
	target := create_render_target({width = SIZE, height = SIZE})
	defer destroy_render_target(&target)
	mesh := create_lit_quad(size)
	defer destroy_mesh(mesh)

	render_target_start(&target, [4]f32{0, 0, 1, 1})
	camera_start(create_screen_camera(SIZE))
	set_shader(shader)
	queue_render(mesh, linalg.MATRIX4F32_IDENTITY, {1, 1, 1, 1}, .NONE, .NONE, {}, {0, 0, 1, 1}, 0)
	set_shader({})
	camera_end()
	render_target_end()

	pixels := read_render_target_pixels(target)
	defer delete(pixels)
	return read_pixel(pixels, SIZE / 2, SIZE / 2)
}

@(test)
the_psx_mesh_shader_snaps_vertices_to_its_grid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device(OPTIONAL_ASSETS)
	defer stop_device(saved)
	if ok == false do return

	psx, loaded := load_shader_checked("psx")
	testing.expect(t, loaded, "optional/shaders/psx.pc.hlsl should load")
	if loaded == false do return
	defer destroy_shader(psx)
	testing.expect(t, (^Shader_Data)(psx.data).has_skinned, "psx_skinned.pc.hlsl sits beside psx and is loaded with it")

	// A quad 1.6 pixels wide centred on the middle of a 16 pixel target, so it covers the pixel centres 7.5 and 8.5. On a grid
	// of 8 cells (2 pixels each) both its edges, at 7.2 and 8.8, round to the same cell corner (8), so the quad has no width and
	// nothing is drawn; on a fine grid it is where it should be. The blue background means the snap ran
	set_shader_value("psx_grid", [2]f32{8, 8}, psx)
	testing.expect_value(t, draw_lit_quad(psx, {1.6, 1.6}), [4]u8{0, 0, 255, 255})

	// Each axis on its own: a quad narrow in x but tall collapses only if x is snapped, and the other way round for y
	testing.expect_value(t, draw_lit_quad(psx, {1.6, 6}), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, draw_lit_quad(psx, {6, 1.6}), [4]u8{0, 0, 255, 255})

	set_shader_value("psx_grid", [2]f32{320, 240}, psx)
	testing.expect_value(t, draw_lit_quad(psx, {1.6, 1.6}), [4]u8{0, 0, 0, 255})

	// Zero reads as 320 x 240 and not as "no cells", which would divide by zero
	set_shader_value("psx_grid", [2]f32{0, 0}, psx)
	testing.expect_value(t, draw_lit_quad(psx, {1.6, 1.6}), [4]u8{0, 0, 0, 255})
}
