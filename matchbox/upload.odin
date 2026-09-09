package matchbox

/*
	Upload
	------
	The staging path shared by everything that goes to the GPU once at load
	time: the unit quad, a sprite's texture, the font atlas.

	SDL3 tracks resource state itself, so the memory barriers and full queue
	waits the previous backend needed around each of these are gone -- an
	upload is a copy pass and a submit. The transfer buffer is temporary and
	released as soon as the copy is recorded.
*/

import "base:runtime"

import sdl "vendor:sdl3"

/*
	Rewrites an existing device buffer from `data`, through a transfer buffer
	the caller keeps and reuses -- the per-frame counterpart to `upload_buffer`
	below, which makes a new device buffer and a throwaway transfer buffer
	every time it is called.

	`cycle` on both the map and the upload: the whole buffer is being replaced
	and nothing already in it is worth waiting for, which is what keeps a
	per-frame rewrite from stalling on the GPU still reading last frame's copy
	-- the same reasoning `pixel_buffer_update` gives for its own texture-shaped
	version of this.

	Recorded on a command buffer of its own rather than the frame's, so the
	caller is not tied to being called between `begin_drawing` and
	`end_drawing` -- correct for anything computed before the frame starts,
	which `update_animator` is. Submission order on the one queue SDL_GPU
	exposes here is what keeps this ordered before whatever draw call reads
	the buffer next, without needing to share a command buffer to prove it.
*/
@(private)
rewrite_buffer :: proc(buffer: ^sdl.GPUBuffer, transfer: ^sdl.GPUTransferBuffer, data: rawptr, size: u32) -> Error {
	device := mbi.renderer.device

	dst := sdl.MapGPUTransferBuffer(device, transfer, true)
	if dst == nil do return Gpu_Error.Transfer_Buffer_Map_Failed
	runtime.mem_copy(dst, data, int(size))
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd  := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		pass,
		{transfer_buffer = transfer, offset = 0},
		{buffer = buffer, offset = 0, size = size},
		true,
	)
	sdl.EndGPUCopyPass(pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) do return Gpu_Error.Submit_Failed

	return nil
}

/*
	Creates a device-local buffer and fills it from `data`.

	Every failure here is the driver refusing an allocation, so they come back
	as `Gpu_Error` rather than stopping the program: the caller is usually a
	loader, and a game that cannot load one model may still have something
	useful to say about it.

	The buffer is released on a later failure. Handing back nil *and* leaking
	the allocation that did succeed would be the worst of both.
*/
@(private)
upload_buffer :: proc(data: rawptr, size: u32, usage: sdl.GPUBufferUsageFlags) -> (^sdl.GPUBuffer, Error) {
	device := mbi.renderer.device

	buffer := sdl.CreateGPUBuffer(device, {usage = usage, size = size})
	if buffer == nil do return nil, Gpu_Error.Buffer_Creation_Failed

	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	if transfer == nil {
		sdl.ReleaseGPUBuffer(device, buffer)
		return nil, Gpu_Error.Transfer_Buffer_Creation_Failed
	}
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)

	dst := sdl.MapGPUTransferBuffer(device, transfer, false)
	if dst == nil {
		sdl.ReleaseGPUBuffer(device, buffer)
		return nil, Gpu_Error.Transfer_Buffer_Map_Failed
	}
	runtime.mem_copy(dst, data, int(size))
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(
		pass,
		{transfer_buffer = transfer, offset = 0},
		{buffer = buffer, offset = 0, size = size},
		false,
	)
	sdl.EndGPUCopyPass(pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) {
		sdl.ReleaseGPUBuffer(device, buffer)
		return nil, Gpu_Error.Submit_Failed
	}

	return buffer, nil
}

/*
	Which GPU format a texture uploads as, and therefore whether the hardware
	decodes it on sample.

	This is not "is the data colour" -- it is "does something downstream
	re-encode it exactly once, the way the tonemap resolve does for the 3D
	pass". A sprite's pixels are colour by any definition and still upload
	`UNORM`: the 2D pass writes straight to an SDR swapchain with no resolve
	step, so a texture decoded to linear on sample would stay linear all the
	way to the screen and every sprite in every 2D game would render dark.
	`SRGB` is therefore for the handful of textures the 3D pass samples as
	colour -- base colour, a skybox -- because that pass is linear end to end
	and the tonemap resolve (`tonemap.odin`) re-encodes the whole scene once,
	after lighting has run on correctly-linear values.

	The glyph atlas (`font.odin`) is `UNORM` for a third reason, not just "2D":
	its bytes are coverage expanded to RGBA, not colour, so there is nothing
	for a decode to mean.

	**Left for P2's next job, not decided here.** Metallic-roughness, normal
	and occlusion textures arrive when `model_load.odin` is extended to read
	them. They are `UNORM`: a roughness value or a tangent-space normal is a
	number the shader reads back exactly, and decoding it through sRGB would
	distort every value that is not precisely 0 or 1 -- the same reason this
	type exists rather than a `bool` that only happened to read right today.
*/
@(private)
Texture_Encoding :: enum {
	UNORM,
	SRGB,
}

// The SDL format `encoding` uploads as. Only the RGBA8 pair matters here --
// nothing in this package uploads a texture in any other bit depth.
@(private)
texture_format :: proc(encoding: Texture_Encoding) -> sdl.GPUTextureFormat {
	return .R8G8B8A8_UNORM_SRGB if encoding == .SRGB else .R8G8B8A8_UNORM
}

/*
	An empty sampled RGBA8 texture. Split out because two things want one: a
	sprite, which fills it once and never again, and a Pixel_Buffer, which is
	created empty and rewritten every frame.

	Both kinds report the same way. This used to `ensure`, on the reasoning
	that a texture the driver will not allocate is a dead program anyway --
	which is true of the built-in font atlas and not true of the twentieth
	image a level asked for, and only the caller knows which it is holding.

	`encoding` has no default -- every caller decides `UNORM` or `SRGB` for
	itself rather than inheriting whichever this happened to default to. See
	`Texture_Encoding`'s own comment for what the choice actually depends on.
*/
@(private)
create_gpu_texture :: proc(width, height: i32, encoding: Texture_Encoding, cube := false) -> (^sdl.GPUTexture, Error) {
	texture := sdl.CreateGPUTexture(mbi.renderer.device, {
		type                 = .CUBE if cube else .D2,
		format               = texture_format(encoding),
		usage                = {.SAMPLER},
		width                = u32(width),
		height               = u32(height),

		// A cube map is six layers of the same square; everything else is one.
		layer_count_or_depth = 6 if cube else 1,
		num_levels           = 1,
	})

	if texture == nil do return nil, Gpu_Error.Texture_Creation_Failed

	return texture, nil
}

/*
	Copies `pixels` into one layer of an existing texture, through a staging
	buffer created and thrown away for the copy.

	The whole of the transfer-buffer dance lives here: create, map, copy, unmap,
	open a copy pass on a command buffer of its own, submit. It was written out
	twice -- once for a whole 2D texture and once for one face of a cube -- and
	the two differed only in whether a layer was named.

	`pixel_buffer.odin` looks like a third copy and is not one, deliberately: it
	keeps its staging buffer alive across frames and records onto the frame's own
	command buffer, which is what orders the upload against the draw that reads
	it. Do not fold it in here.
*/
@(private)
upload_texture_region :: proc(
	texture: ^sdl.GPUTexture,
	pixels:  rawptr,
	width, height: i32,
	layer:   u32 = 0,
) -> Error {
	device := mbi.renderer.device
	size   := u32(width) * u32(height) * 4

	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	if transfer == nil do return Gpu_Error.Transfer_Buffer_Creation_Failed
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)

	dst := sdl.MapGPUTransferBuffer(device, transfer, false)
	if dst == nil do return Gpu_Error.Transfer_Buffer_Map_Failed
	runtime.mem_copy(dst, pixels, int(size))
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd  := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		pass,
		{transfer_buffer = transfer, offset = 0, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = texture, layer = layer, w = u32(width), h = u32(height), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(pass)

	if !sdl.SubmitGPUCommandBuffer(cmd) do return Gpu_Error.Submit_Failed

	return nil
}

// Creates a sampled RGBA8 texture and fills it from `pixels`, which must hold
// width * height * 4 bytes. The texture is released if the fill fails, so a
// caller that gets an error is not also holding something to free.
//
// `encoding` has no default -- see `Texture_Encoding` and `create_gpu_texture`.
@(private)
upload_texture :: proc(pixels: rawptr, width, height: i32, encoding: Texture_Encoding) -> (^sdl.GPUTexture, Error) {
	texture, err := create_gpu_texture(width, height, encoding)
	if err != nil do return nil, err

	if fill_err := upload_texture_region(texture, pixels, width, height); fill_err != nil {
		sdl.ReleaseGPUTexture(mbi.renderer.device, texture)
		return nil, fill_err
	}

	return texture, nil
}

/*
	Binds everything a run of quads has in common: the pipeline, the shared
	quad's vertex and index buffers, and the texture to sample from. `texture`
	is nil for the shapes that do not sample one.

	Separate from the draw so a run can bind once. A string of text is one
	pipeline and one atlas however many characters it has, and binding all of
	that again per glyph is work with no effect -- a twenty character line was
	doing it twenty times.

	Returns false when the frame has no pass to record into, in which case there
	is nothing to draw and the caller should stop rather than push uniforms into
	the void.
*/
@(private)
bind_quad_state :: proc(
	pipeline: ^sdl.GPUGraphicsPipeline,
	texture:  ^sdl.GPUTexture = nil,
	sampler:  ^sdl.GPUSampler = nil,
) -> bool {
	r := &mbi.renderer
	if !r.frame_active do return false

	// A 2D pipeline declares no depth-stencil target and the 3D pass has one,
	// so binding it here is a validation failure rather than a wrong picture.
	// Draw the HUD after end_drawing_3d, which is the order both games use.
	ensure(!r.mode_3d, "2D drawing cannot go between begin_drawing_3d and end_drawing_3d")

	ensure_pass()
	if r.pass == nil do return false

	// Only what has actually changed. Binding is pass state and the driver does
	// not check for you, so a run of identical draws was describing the same
	// pipeline and the same two buffers over and over.
	if r.bound_pipeline != pipeline {
		sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
		r.bound_pipeline = pipeline
	}

	// The quad is the same four vertices and six indices for the life of the
	// program, so this is once per pass rather than once per draw.
	if !r.bound_quad {
		vertex_binding := sdl.GPUBufferBinding{buffer = r.quad_verts, offset = 0}
		sdl.BindGPUVertexBuffers(r.pass, 0, &vertex_binding, 1)
		sdl.BindGPUIndexBuffer(r.pass, {buffer = r.quad_indices, offset = 0}, ._32BIT)
		r.bound_quad = true
	}

	if texture != nil && (r.bound_texture != texture || r.bound_sampler != sampler) {
		binding := sdl.GPUTextureSamplerBinding{texture = texture, sampler = sampler}
		sdl.BindGPUFragmentSamplers(r.pass, 0, &binding, 1)
		r.bound_texture = texture
		r.bound_sampler = sampler
	}

	return true
}

// Hands a fragment uniform block over on its own, for a run of draws that all
// want the same one. It stays in force until something pushes over it.
@(private)
push_frag_uniform :: proc(frag_data: rawptr, frag_size: u32) {
	if frag_size > 0 do sdl.PushGPUFragmentUniformData(mbi.renderer.cmd, 0, frag_data, frag_size)
}

/*
	Draws one quad against whatever bind_quad_state last set up.

	The uniform pushes go to the command buffer rather than the pass, and SDL3
	ring-buffers them per frame, which is what replaced the three cycled arenas
	the old backend needed. Only call this after bind_quad_state has returned
	true.
*/
@(private)
push_quad :: proc(vert_data: ^Vert_Data, frag_data: rawptr, frag_size: u32) {
	r := &mbi.renderer

	sdl.PushGPUVertexUniformData(r.cmd, 0, vert_data, size_of(Vert_Data))

	// sprite.frag declares no uniform buffer, so there is nothing to push and
	// pushing anyway would be handing data to a slot the shader does not have.
	if frag_size > 0 {
		sdl.PushGPUFragmentUniformData(r.cmd, 0, frag_data, frag_size)
	}

	sdl.DrawGPUIndexedPrimitives(r.pass, 6, 1, 0, 0, 0)
}

// Bind and draw together, which is what everything drawing a single quad wants.
@(private)
draw_quad :: proc(
	pipeline:  ^sdl.GPUGraphicsPipeline,
	vert_data: ^Vert_Data,
	frag_data: rawptr,
	frag_size: u32,
	texture:   ^sdl.GPUTexture = nil,
	sampler:   ^sdl.GPUSampler = nil,
) {
	if !bind_quad_state(pipeline, texture, sampler) do return
	push_quad(vert_data, frag_data, frag_size)
}
