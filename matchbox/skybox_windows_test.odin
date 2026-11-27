#+build windows

package matchbox

/*
	The sky drawn on a real D3D11 device (the software one, WARP) into a render target and read back pixel by pixel.
	Every face and half is a colour with channels of 0 or 255, which the colour handling leaves alone, so the expected
	values are exact. Where the view direction is on a seam of the cube the test looks a little off it
*/

import "core:sync"
import "core:testing"

import win "core:sys/windows"
import "vendor:directx/d3d11"

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
SIZE :: 32

/*What the camera at the origin looking along `direction` sees at the middle of a 32 x 32 target*/
@(private="file")
look :: proc(sky:Skybox, direction:[3]f32, up:[3]f32 = {0, 1, 0}) -> [4]u8 {
	pixels := look_at_pixels(sky, direction, up)
	defer delete(pixels)
	return pixel_at(pixels, SIZE / 2, SIZE / 2)
}

@(private="file")
look_at_pixels :: proc(sky:Skybox, direction:[3]f32, up:[3]f32 = {0, 1, 0}) -> []u8 {
	target := create_render_target({width = SIZE, height = SIZE})
	defer destroy_render_target(&target)

	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera := create_camera_3d({0, 0, 0}, direction, 70)
	camera.up = up
	camera_start(camera)
	render_skybox(sky)
	camera_end()
	render_target_end()
	return read_render_target_pixels(target)
}

@(private="file")
pixel_at :: proc(pixels:[]u8, width, x:int, y:int = -1) -> [4]u8 {
	row := y if y >= 0 else x
	offset := (row * width + x) * 4
	return {pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]}
}

@(private="file")
FACE_COLORS :: [6][4]u8 {
	{255, 0, 0, 255}, // face 0, labelled +X
	{0, 255, 0, 255}, // face 1, -X
	{0, 0, 255, 255}, // face 2, +Y
	{255, 255, 0, 255}, // face 3, -Y
	{255, 0, 255, 255}, // face 4, +Z
	{0, 255, 255, 255}, // face 5, -Z
}

@(private="file")
make_solid_sky :: proc(faces:^[6][16][4]u8) -> Skybox {
	colors := FACE_COLORS
	pointers:[6]rawptr
	for &face, index in faces {
		for &pixel in face do pixel = colors[index]
		pointers[index] = &face
	}
	return create_skybox_cubemap(pointers, 4)
}

@(test)
each_of_the_six_directions_sees_the_face_it_should :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	faces:[6][16][4]u8
	sky := make_solid_sky(&faces)
	defer destroy_skybox(sky)

	colors := FACE_COLORS
	// Looking toward a world direction shows the face a left-handed cube map has there. +X and -X are swapped against
	// their labels, because the cube map is sampled left-handed and the world is not (shaders/skybox.pc.hlsl);
	// -Z, straight ahead of an unturned camera, is the cell labelled -Z
	testing.expect_value(t, look(sky, {1, 0, 0}), colors[1])
	testing.expect_value(t, look(sky, {-1, 0, 0}), colors[0])
	testing.expect_value(t, look(sky, {0, 1, 0}, {0, 0, 1}), colors[2])
	testing.expect_value(t, look(sky, {0, -1, 0}, {0, 0, 1}), colors[3])
	testing.expect_value(t, look(sky, {0, 0, 1}), colors[4])
	testing.expect_value(t, look(sky, {0, 0, -1}), colors[5])
}

@(test)
the_sky_is_not_mirrored :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// The -Z face, the one straight ahead, with its left half red and its right half blue as the picture is seen
	// from inside. Turning to the right must show blue: a mirrored sky shows red
	faces:[6][16][4]u8
	colors := FACE_COLORS
	for &face, index in faces {
		for &pixel in face do pixel = colors[index]
	}
	for y in 0 ..< 4 {
		for x in 0 ..< 4 do faces[5][y * 4 + x] = {255, 0, 0, 255} if x < 2 else {0, 0, 255, 255}
	}
	pointers:[6]rawptr
	for &face, index in faces do pointers[index] = &face
	sky := create_skybox_cubemap(pointers, 4)
	defer destroy_skybox(sky)

	pixels := look_at_pixels(sky, {0, 0, -1})
	defer delete(pixels)
	testing.expect_value(t, pixel_at(pixels, SIZE, 4, 16), [4]u8{255, 0, 0, 255}) // the left of the picture
	testing.expect_value(t, pixel_at(pixels, SIZE, 27, 16), [4]u8{0, 0, 255, 255}) // the right of it

	// Walk the camera's right across the seam into the next cell: world +X is the cell labelled -X (green), and the
	// view that straddles the two shows the -Z face's blue on the left and the green on the right
	pixels2 := look_at_pixels(sky, {1, 0, -1})
	defer delete(pixels2)
	testing.expect_value(t, pixel_at(pixels2, SIZE, 4, 16), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, pixel_at(pixels2, SIZE, 27, 16), [4]u8{0, 255, 0, 255})
}

@(test)
a_panorama_has_its_middle_ahead_and_its_right_to_the_right :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	// 8 x 4. The picture is the full 360 degrees: u 0.5 is straight ahead (-Z), u 0.75 toward +X, u 0.25 toward -X, and
	// u 0 and 1 are behind (+Z). Each direction's centre falls in the middle of a stripe
	pixels:[8 * 4][4]u8
	for y in 0 ..< 4 {
		for x in 0 ..< 8 {
			color:[4]u8
			switch x {
			case 0, 7: color = {255, 255, 0, 255} // behind
			case 1, 2: color = {0, 255, 0, 255} // toward -X
			case 3, 4: color = {255, 0, 0, 255} // ahead
			case 5, 6: color = {0, 0, 255, 255} // toward +X
			}
			pixels[y * 8 + x] = color
		}
	}
	sky := create_skybox_panorama(&pixels, 8, 4)
	defer destroy_skybox(sky)

	testing.expect_value(t, look(sky, {0, 0, -1}), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, look(sky, {1, 0, 0}), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, look(sky, {-1, 0, 0}), [4]u8{0, 255, 0, 255})
	testing.expect_value(t, look(sky, {0, 0, 1}), [4]u8{255, 255, 0, 255})
}

@(test)
the_sky_is_behind_everything_and_the_tint_multiplies_it :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	saved, ok := start_device()
	defer stop_device(saved)
	if ok == false do return

	faces:[6][16][4]u8
	sky := make_solid_sky(&faces)
	defer destroy_skybox(sky)
	sky.tint = {1, 1, 1, 1}

	// A near rectangle covers the middle even though the sky is recorded after it: the sky is drawn first, whatever
	// the order of the calls, and writes no depth
	target := create_render_target({width = SIZE, height = SIZE})
	defer destroy_render_target(&target)
	render_target_start(&target, [4]f32{0, 0, 0, 1})
	camera_start(create_camera_3d({0, 0, 0}, {0, 0, -1}, 70))
	render_rectangle({0, 0, -2}, {1, 1}, {1, 1, 1, 1})
	render_skybox(sky)
	camera_end()
	render_target_end()
	pixels := read_render_target_pixels(target, context.temp_allocator)
	testing.expect_value(t, pixel_at(pixels, SIZE, 16, 16), [4]u8{255, 255, 255, 255})
	testing.expect_value(t, pixel_at(pixels, SIZE, 1, 1), FACE_COLORS[5]) // the corner is still the sky

	// Tint multiplies per channel: a tint of {1, 0, 1} turns the cyan (0, 255, 255) straight ahead to blue
	sky.tint = {1, 0, 1, 1}
	blue := look(sky, {0, 0, -1})
	testing.expect_value(t, blue, [4]u8{0, 0, 255, 255})
}
