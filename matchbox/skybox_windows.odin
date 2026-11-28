#+build windows

package matchbox

/*
	Skybox (PC)
	===========
	Types and the maths are in skybox.odin. This is the D3D11 half: the textures, the one hand-written shader
	(shaders/skybox.pc.hlsl) and the draw.

	`render_skybox` only records which sky to draw, like every other render_ call. camera_end draws it first, before the
	opaque items, with depth off, so it is a background and not a very large object.
*/

import win "core:sys/windows"
import "core:image"
import "core:slice"

import "vendor:directx/d3d11"

/*What only a PC skybox has: its texture, a cube for a cube map and a plain 2D one for a panorama. Embedded in Skybox with `using`*/
Backend_Skybox :: struct {
	texture:^d3d11.ITexture2D,
	view:^d3d11.IShaderResourceView,
}

/*The sky's shader and what it draws with, made once by create_pipeline. `pending` is the sky render_skybox recorded for this camera*/
Skybox_State :: struct {
	vertex_shader:^d3d11.IVertexShader,
	cubemap_shader:^d3d11.IPixelShader,
	panorama_shader:^d3d11.IPixelShader,
	constants:^d3d11.IBuffer,
	sampler:^d3d11.ISamplerState,
	pending:Skybox,
	has_pending:bool,
}

// Matches skybox_block in shaders/skybox.pc.hlsl
@(private = "file")
Skybox_Constants :: struct {
	rays:Skybox_Rays,
	tint:[4]f32,
}
#assert(size_of(Skybox_Constants) == 64)

/*
	A cube map from six faces of `face_size` x `face_size` RGBA pixels (8 bits a channel), in the order +X, -X, +Y, -Y,
	+Z, -Z, labelled as a cube map is (see skybox.odin on handedness). The caller owns the pixels and can free them afterwards.

	The colour is stored plain, not as sRGB, like every picture load_texture reads: a sky and the same image drawn as a
	sprite show the same colour
*/
create_skybox_cubemap :: proc(faces:[6]rawptr, face_size:i32) -> (skybox:Skybox) {
	ensure(face_size > 0, "A skybox face needs a size")
	make_skybox_state()

	description := d3d11.TEXTURE2D_DESC {
		Width = u32(face_size),
		Height = u32(face_size),
		MipLevels = 1,
		ArraySize = 6,
		Format = .R8G8B8A8_UNORM,
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
		MiscFlags = {.TEXTURECUBE},
		SampleDesc = {Count = 1},
	}

	data:[6]d3d11.SUBRESOURCE_DATA
	for face, index in faces {
		ensure(face != nil, "A skybox face has no pixels")
		data[index] = {pSysMem = face, SysMemPitch = u32(face_size * 4)}
	}

	result := mbi.device->CreateTexture2D(&description, &data[0], &skybox.texture)
	ensure(win.SUCCEEDED(result), "Create skybox cube texture failed")
	// No view description: D3D reads a cube texture as a cube
	result = mbi.device->CreateShaderResourceView(skybox.texture, nil, &skybox.view)
	ensure(win.SUCCEEDED(result), "Create skybox cube view failed")

	skybox.kind = .CUBEMAP
	skybox.tint = {1, 1, 1, 1}
	return
}

/*A panorama from RGBA pixels (8 bits a channel, `width * 4` bytes a row) of an equirectangular picture, normally 2:1. The
caller owns the pixels and can free them afterwards*/
create_skybox_panorama :: proc(pixels:rawptr, width, height:i32) -> (skybox:Skybox) {
	make_skybox_state()
	description := d3d11.TEXTURE2D_DESC {
		Width = u32(width),
		Height = u32(height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
		SampleDesc = {Count = 1},
	}
	data := d3d11.SUBRESOURCE_DATA{pSysMem = pixels, SysMemPitch = u32(width * 4)}

	result := mbi.device->CreateTexture2D(&description, &data, &skybox.texture)
	ensure(win.SUCCEEDED(result), "Create skybox panorama failed")
	result = mbi.device->CreateShaderResourceView(skybox.texture, nil, &skybox.view)
	ensure(win.SUCCEEDED(result), "Create skybox panorama view failed")

	skybox.kind = .PANORAMA
	skybox.tint = {1, 1, 1, 1}
	return
}

/*
	A cube map from a picture of a horizontal cross in assets/images: four cells across, three down, 4:3 (see
	split_cubemap_cross). Stops with a message if the picture is any other shape, since a vertical cross cut as if it were
	horizontal would load into six wrong faces without complaint
*/
load_skybox_cubemap :: proc(filename:string) -> (skybox:Skybox) {
	ok:bool
	skybox, ok = load_skybox_cubemap_checked(filename)
	ensure(ok, "Failed to load the cube map: see the message above")
	return
}

/*The same as load_skybox_cubemap, but a missing file, one that will not decode, one that is not 8 bits a channel or a picture of the wrong shape is `ok` = false (with the reason printed) and not a stop. Nothing is allocated when `ok` is false*/
load_skybox_cubemap_checked :: proc(filename:string) -> (skybox:Skybox, ok:bool) {
	pixels, width, height, read_ok := read_skybox_image(filename)
	if read_ok == false do return {}, false
	defer delete(pixels)

	faces, face_size, split_ok := split_cubemap_cross(pixels, width, height)
	if split_ok == false {
		print(filename, "is not a horizontal cross of square faces: four cells across, three down")
		return {}, false
	}
	defer delete(faces[0])

	return create_skybox_cubemap({raw_data(faces[0]), raw_data(faces[1]), raw_data(faces[2]), raw_data(faces[3]), raw_data(faces[4]), raw_data(faces[5])}, i32(face_size)), true
}

/*A panorama from an equirectangular picture in assets/images. Meant to be 2:1; another ratio still loads, a crop being
legitimate, but a cube cross handed to this loader looks like a squashed sky that turns at the wrong rate*/
load_skybox_panorama :: proc(filename:string) -> (skybox:Skybox) {
	ok:bool
	skybox, ok = load_skybox_panorama_checked(filename)
	ensure(ok, "Failed to load the panorama: see the message above")
	return
}

/*The same as load_skybox_panorama, but a missing file, one that will not decode or one that is not 8 bits a channel is `ok` = false (with the reason printed) and not a stop. Nothing is allocated when `ok` is false*/
load_skybox_panorama_checked :: proc(filename:string) -> (skybox:Skybox, ok:bool) {
	pixels, width, height, read_ok := read_skybox_image(filename)
	if read_ok == false do return {}, false
	defer delete(pixels)

	ratio := f32(width) / f32(height)
	if abs(ratio - 2) > 0.01 {
		print(filename, "is", width, "x", height, ", not the 2:1 of an equirectangular panorama")
	}
	return create_skybox_panorama(raw_data(pixels), i32(width), i32(height)), true
}

/*Reads a picture as RGBA pixels, or says why it could not (printed). The caller deletes the pixels*/
@(private = "file")
read_skybox_image :: proc(filename:string) -> (pixels:[][4]u8, width, height:int, ok:bool) {
	path, found := find_asset(filename, .IMAGE)
	if found == false {
		print("No such image file:", filename)
		return nil, 0, 0, false
	}
	defer delete(path)

	loaded, err := image.load_from_file(path, options = {.alpha_add_if_missing})
	if err != nil {
		print("Could not read image", path)
		return nil, 0, 0, false
	}
	defer image.destroy(loaded)
	if loaded.depth != 8 || loaded.channels != 4 {
		print("A skybox picture must be 8 bits per channel:", path)
		return nil, 0, 0, false
	}

	pixels = slice.clone(slice.reinterpret([][4]u8, loaded.pixels[:]))
	return pixels, loaded.width, loaded.height, true
}

/*Frees the sky's texture*/
destroy_skybox :: proc(skybox:Skybox) {
	if skybox.view != nil do skybox.view->Release()
	if skybox.texture != nil do skybox.texture->Release()
}

/*Draws `skybox` behind everything in the camera being drawn, at camera_end. Only the camera's rotation is used: a sky
is infinitely far. Call it once per camera; a second call replaces the first. A 3D camera only: a screen camera has no
direction to look in*/
render_skybox :: proc(skybox:Skybox) {
	ensure(mbi.camera_active == true, "Drawing must happen between camera_start and camera_end")
	ensure(mbi.screen_pass == false, "A skybox needs a 3D camera, not a screen camera")
	ensure(skybox.view != nil, "render_skybox needs a skybox from load_skybox_cubemap, load_skybox_panorama or their create_ versions")

	mbi.skybox.pending = skybox
	mbi.skybox.has_pending = true
}

/*Draws the sky render_skybox recorded, if any. camera_end calls it before the first item*/
@(private)
draw_pending_skybox :: proc() {
	state := &mbi.skybox
	if state.has_pending == false do return
	state.has_pending = false
	sky := state.pending

	// An orthographic camera has no angle (its size is in world units), so it is given a perspective one: a sky with no
	// perspective is a single flat colour, which is never what was wanted
	fov_y := mbi.camera_fov_y if mbi.camera_fov_y > 0 else 70
	constants := Skybox_Constants{rays = calculate_skybox_rays(mbi.view, fov_y, calculate_window_aspect()), tint = sky.tint}
	update_buffer(state.constants, &constants, size_of(Skybox_Constants))

	// No culling: the triangle is generated, and winding is not worth getting right for something drawn once
	set_render_state(.DISABLED, .NONE, .NONE)

	context_ := mbi.device_context
	context_->IASetPrimitiveTopology(.TRIANGLELIST)
	context_->IASetInputLayout(nil)
	context_->VSSetShader(state.vertex_shader, nil, 0)
	context_->PSSetShader(state.cubemap_shader if sky.kind == .CUBEMAP else state.panorama_shader, nil, 0)

	buffer := state.constants
	context_->VSSetConstantBuffers(0, 1, &buffer)
	context_->PSSetConstantBuffers(0, 1, &buffer)

	view := sky.view
	sampler := state.sampler
	context_->PSSetShaderResources(0, 1, &view)
	context_->PSSetSamplers(0, 1, &sampler)

	context_->Draw(3, 0)
}

/*
	Makes the sky's state the first time a sky is made, and not before: it is a shader compile, and a game with no sky
	should not pay for one at startup. Not in `create_pipeline`, where it used to be
*/
@(private = "file")
make_skybox_state :: proc() {
	if mbi.skybox.constants == nil do create_skybox_state()
}

/*Compiles the sky's shaders and makes its buffer and sampler. Called once, by make_skybox_state*/
@(private)
create_skybox_state :: proc() {
	source := #load("shaders/skybox.pc.hlsl")
	state := &mbi.skybox

	vertex_blob:^d3d11.IBlob
	cubemap_blob:^d3d11.IBlob
	panorama_blob:^d3d11.IBlob
	compile_shader(source, "shaders/skybox.pc.hlsl", "vertex_main", "vs_5_0", &vertex_blob)
	compile_shader(source, "shaders/skybox.pc.hlsl", "fragment_cubemap", "ps_5_0", &cubemap_blob)
	compile_shader(source, "shaders/skybox.pc.hlsl", "fragment_panorama", "ps_5_0", &panorama_blob)
	// The bytecode is copied by the device, so the blobs are not kept (there is no input layout to need the vertex one)
	defer vertex_blob->Release()
	defer cubemap_blob->Release()
	defer panorama_blob->Release()

	result := mbi.device->CreateVertexShader(vertex_blob->GetBufferPointer(), vertex_blob->GetBufferSize(), nil, &state.vertex_shader)
	ensure(win.SUCCEEDED(result), "Skybox vertex shader creation failed")
	result = mbi.device->CreatePixelShader(cubemap_blob->GetBufferPointer(), cubemap_blob->GetBufferSize(), nil, &state.cubemap_shader)
	ensure(win.SUCCEEDED(result), "Skybox cube map shader creation failed")
	result = mbi.device->CreatePixelShader(panorama_blob->GetBufferPointer(), panorama_blob->GetBufferSize(), nil, &state.panorama_shader)
	ensure(win.SUCCEEDED(result), "Skybox panorama shader creation failed")

	state.constants = create_constant_buffer(size_of(Skybox_Constants))

	// Wraps across u so a panorama's seam is smooth; clamps down v so the poles do not bleed into each other
	sampler_description := d3d11.SAMPLER_DESC {
		Filter = .MIN_MAG_MIP_LINEAR,
		AddressU = .WRAP,
		AddressV = .CLAMP,
		AddressW = .CLAMP,
		ComparisonFunc = .NEVER,
		MaxLOD = d3d11.FLOAT32_MAX,
	}
	result = mbi.device->CreateSamplerState(&sampler_description, &state.sampler)
	ensure(win.SUCCEEDED(result), "Create skybox sampler failed")
}

@(private)
destroy_skybox_state :: proc() {
	state := &mbi.skybox
	if state.sampler != nil do state.sampler->Release()
	if state.constants != nil do state.constants->Release()
	if state.panorama_shader != nil do state.panorama_shader->Release()
	if state.cubemap_shader != nil do state.cubemap_shader->Release()
	if state.vertex_shader != nil do state.vertex_shader->Release()
	state^ = {}
}
