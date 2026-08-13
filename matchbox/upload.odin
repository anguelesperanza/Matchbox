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

// Creates a device-local buffer and fills it from `data`.
@(private)
upload_buffer :: proc(data: rawptr, size: u32, usage: sdl.GPUBufferUsageFlags) -> ^sdl.GPUBuffer {
	device := mbi.renderer.device

	buffer := sdl.CreateGPUBuffer(device, {usage = usage, size = size})
	ensure(buffer != nil, "could not create GPU buffer")

	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	ensure(transfer != nil, "could not create transfer buffer")
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)

	dst := sdl.MapGPUTransferBuffer(device, transfer, false)
	ensure(dst != nil, "could not map transfer buffer")
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
	ensure(sdl.SubmitGPUCommandBuffer(cmd), "could not submit buffer upload")

	return buffer
}

// Creates a sampled RGBA8 texture and fills it from `pixels`, which must hold
// width * height * 4 bytes.
@(private)
upload_texture :: proc(pixels: rawptr, width, height: i32) -> ^sdl.GPUTexture {
	device := mbi.renderer.device
	size   := u32(width) * u32(height) * 4

	texture := sdl.CreateGPUTexture(device, {
		type                 = .D2,
		format               = .R8G8B8A8_UNORM,
		usage                = {.SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	ensure(texture != nil, "could not create GPU texture")

	transfer := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	ensure(transfer != nil, "could not create transfer buffer")
	defer sdl.ReleaseGPUTransferBuffer(device, transfer)

	dst := sdl.MapGPUTransferBuffer(device, transfer, false)
	ensure(dst != nil, "could not map transfer buffer")
	runtime.mem_copy(dst, pixels, int(size))
	sdl.UnmapGPUTransferBuffer(device, transfer)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	pass := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		pass,
		{transfer_buffer = transfer, offset = 0, pixels_per_row = u32(width), rows_per_layer = u32(height)},
		{texture = texture, w = u32(width), h = u32(height), d = 1},
		false,
	)
	sdl.EndGPUCopyPass(pass)
	ensure(sdl.SubmitGPUCommandBuffer(cmd), "could not submit texture upload")

	return texture
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

	ensure_pass()
	if r.pass == nil do return false

	sdl.BindGPUGraphicsPipeline(r.pass, pipeline)

	vertex_binding := sdl.GPUBufferBinding{buffer = r.quad_verts, offset = 0}
	sdl.BindGPUVertexBuffers(r.pass, 0, &vertex_binding, 1)
	sdl.BindGPUIndexBuffer(r.pass, {buffer = r.quad_indices, offset = 0}, ._32BIT)

	if texture != nil {
		binding := sdl.GPUTextureSamplerBinding{texture = texture, sampler = sampler}
		sdl.BindGPUFragmentSamplers(r.pass, 0, &binding, 1)
	}

	return true
}

/*
	Draws one quad against whatever bind_quad_state last set up.

	The uniform pushes go to the command buffer rather than the pass, and SDL3
	ring-buffers them per frame, which is what replaced the three cycled arenas
	the old backend needed. Only call this after bind_quad_state has returned
	true.
*/
@(private)
push_quad :: proc(vert_data: ^VertData, frag_data: rawptr, frag_size: u32) {
	r := &mbi.renderer

	sdl.PushGPUVertexUniformData(r.cmd, 0, vert_data, size_of(VertData))

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
	vert_data: ^VertData,
	frag_data: rawptr,
	frag_size: u32,
	texture:   ^sdl.GPUTexture = nil,
	sampler:   ^sdl.GPUSampler = nil,
) {
	if !bind_quad_state(pipeline, texture, sampler) do return
	push_quad(vert_data, frag_data, frag_size)
}
