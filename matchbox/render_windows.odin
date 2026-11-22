#+build windows

package matchbox

/*
	Render
	======
	Handles the rendering

	PC (D3D11). Everything drawn is 3D; 2D is an orthographic camera.

	Drawing is queued: render_mesh (and render_sprite / the shapes) only record
	a Render_Item between camera_start and camera_end. camera_end sorts the queue
	and issues the draw calls. See render_plan.md.
*/

import win "core:sys/windows"
import "core:mem"
import "core:slice"
import "core:strings"

import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

Frame_Constants :: struct {
	view_projection:matrix[4,4]f32,
	time:f32, // seconds; the shader language's frame.time. Not filled in yet, so it is 0
	_pad:[3]f32,
}

Render_Constants :: struct {
	model:matrix[4,4]f32,
	tint:[4]f32,
	uv_rectangle:[4]f32, // matched to mesh.mbs by name: renaming it means regenerating every shader, the Vita .gxp included
	alpha_cutoff:f32,
	_pad:[3]f32
}

// D3D constant buffers must be a multiple of 16 bytes
#assert(size_of(Frame_Constants) % 16 == 0)
#assert(size_of(Render_Constants) % 16 == 0)

// linalg builds OpenGL clip space (depth -1..1); D3D wants 0..1: z_new = 0.5 * z + 0.5 * w
GL_TO_D3D_DEPTH :: matrix[4, 4]f32 {
	1, 0, 0,   0,
	0, 1, 0,   0,
	0, 0, 0.5, 0.5,
	0, 0, 0,   1,
}

Depth_Mode :: enum {
	OPAQUE,
	TRANSPARENT,
	DISABLED,
}



// Geometry on the GPU. `create_mesh` makes one, `destroy_mesh` frees it.
Mesh :: struct {
	vertex_buffer:^d3d11.IBuffer,
	index_buffer:^d3d11.IBuffer,
	index_count:u32,
}


/*Copies vertices and indices to the GPU. The slices can be freed afterwards*/
create_mesh :: proc(vertices:[]Vertex, indices:[]u16) -> (mesh:Mesh) {
	assert(len(vertices) > 0 && len(indices) > 0, "A mesh needs vertices and indices")
	assert(len(vertices) <= 65536, "A mesh with 16-bit indices can have at most 65536 vertices")

	vertex_description := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertices) * size_of(Vertex)),
		Usage = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vertex_data := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(vertices)}

	result := mbi.device->CreateBuffer(&vertex_description, &vertex_data, &mesh.vertex_buffer)
	ensure(win.SUCCEEDED(result), "Create mesh vertex buffer failed")

	index_description := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(indices) * size_of(u16)),
		Usage = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	index_data := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(indices)}

	result = mbi.device->CreateBuffer(&index_description, &index_data, &mesh.index_buffer)
	ensure(win.SUCCEEDED(result), "Create mesh index buffer failed")

	mesh.index_count = u32(len(indices))
	return
}

destroy_mesh :: proc(mesh:Mesh) {
	if mesh.index_buffer != nil do mesh.index_buffer->Release()
	if mesh.vertex_buffer != nil do mesh.vertex_buffer->Release()
}



/*Issues the draw call for one queued item. The render state is already set*/
@(private)
render_item :: proc(item:Render_Item) {
	set_render_constants(item.model, item.tint, item.uv_rectangle, item.alpha_cutoff)

	vertex_buffer := item.mesh.vertex_buffer
	stride:u32 = size_of(Vertex)
	offset:u32 = 0

	upload_game_constants()

	mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	mbi.device_context->IASetInputLayout(mbi.input_layout)
	mbi.device_context->IASetVertexBuffers(0, 1, &vertex_buffer, &stride, &offset)
	mbi.device_context->IASetIndexBuffer(item.mesh.index_buffer, .R16_UINT, 0)

	mbi.device_context->VSSetShader(mbi.vertex_shader, nil, 0)
	mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)

	// Each constant buffer goes to the register the shader's reflection file names
	buffers := [Block_Kind]^d3d11.IBuffer{.FRAME = mbi.frame_constants, .RENDER = mbi.render_constants, .GAME = mbi.game_constants}
	for block, kind in mbi.reflection.blocks {
		if block.present == false do continue
		buffer := buffers[kind]
		mbi.device_context->VSSetConstantBuffers(u32(block.register), 1, &buffer)
		mbi.device_context->PSSetConstantBuffers(u32(block.register), 1, &buffer)
	}

	// The draw's texture goes to the first texture the shader declares; any others get plain white, which leaves
	// the colour as it is when it is multiplied in
	for texture, index in mbi.reflection.textures {
		texture_view := item.texture.view if index == 0 else nil
		if texture_view == nil do texture_view = mbi.white_texture_view
		mbi.device_context->PSSetShaderResources(u32(texture.slot), 1, &texture_view)
	}
	if mbi.reflection.has_sampler {
		mbi.device_context->PSSetSamplers(u32(mbi.reflection.sampler), 1, &mbi.samplers[item.texture.filter])
	}

	mbi.device_context->DrawIndexed(item.mesh.index_count, 0, 0)
}

/*Creates every depth, blend, rasterizer and sampler state once. set_render_state picks between them*/
@(private)
create_states :: proc() {
	stencil_op := d3d11.DEPTH_STENCILOP_DESC {
		StencilFailOp = .KEEP,
		StencilDepthFailOp = .KEEP,
		StencilPassOp = .KEEP,
		StencilFunc = .ALWAYS,
	}

	depth_descs := [Depth_Mode]d3d11.DEPTH_STENCIL_DESC {
		.OPAQUE = {
			DepthEnable = true,
			DepthWriteMask = .ALL,
			DepthFunc = .LESS,
			FrontFace = stencil_op,
			BackFace = stencil_op,
		},
		.TRANSPARENT = {
			DepthEnable = true,
			DepthWriteMask = .ZERO,
			DepthFunc = .LESS,
			FrontFace = stencil_op,
			BackFace = stencil_op,
		},
		.DISABLED = {
			DepthEnable = false,
			DepthWriteMask = .ZERO,
			DepthFunc = .ALWAYS,
			FrontFace = stencil_op,
			BackFace = stencil_op,
		},
	}

	for &description, mode in depth_descs {
		result := mbi.device->CreateDepthStencilState(&description, &mbi.depth_states[mode])
		ensure(win.SUCCEEDED(result), "Create DepthStencilState Failed")
	}

	// Blend
	blend_descs: [Blend_Mode]d3d11.BLEND_DESC

	blend_descs[.NONE].RenderTarget[0] = {
		BlendEnable = false,
		SrcBlend = .ONE,
		DestBlend = .ZERO,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .ZERO,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = 0xF, // R | G | B | A
	}

	blend_descs[.ALPHA].RenderTarget[0] = {
		BlendEnable = true,
		SrcBlend = .SRC_ALPHA,
		DestBlend = .INV_SRC_ALPHA,
		BlendOp = .ADD,
		SrcBlendAlpha = .ONE,
		DestBlendAlpha = .INV_SRC_ALPHA,
		BlendOpAlpha = .ADD,
		RenderTargetWriteMask = 0xF,
	}

	for &description, mode in blend_descs {
		result := mbi.device->CreateBlendState(&description, &mbi.blend_states[mode])
		ensure(win.SUCCEEDED(result), "Create BlendState Failed")
	}

	rasterizer_descs := [Cull_Mode]d3d11.RASTERIZER_DESC {
		.BACK = {
			FillMode = .SOLID,
			CullMode = .BACK,
			FrontCounterClockwise = true,
			DepthClipEnable = true,
		},

		.NONE = {
			FillMode = .SOLID,
			CullMode = .NONE,
			FrontCounterClockwise = true,
			DepthClipEnable = true,
		},
	}

	for &description, mode in rasterizer_descs {
		result := mbi.device->CreateRasterizerState(&description, &mbi.rasterizer_states[mode])
		ensure(win.SUCCEEDED(result), "Create RasterizerState Failed")
	}

	sampler_descs := [Filter_Mode]d3d11.SAMPLER_DESC {
		.POINT = {
			Filter = .MIN_MAG_MIP_POINT,
			AddressU = .CLAMP,
			AddressV = .CLAMP,
			AddressW = .CLAMP,
			ComparisonFunc = .NEVER,
			MaxLOD = d3d11.FLOAT32_MAX,
		},
		.LINEAR = {
			Filter = .MIN_MAG_MIP_LINEAR,
			AddressU = .CLAMP,
			AddressV = .CLAMP,
			AddressW = .CLAMP,
			ComparisonFunc = .NEVER,
			MaxLOD = d3d11.FLOAT32_MAX,
		},
	}

	for &description, mode in sampler_descs {
		result := mbi.device->CreateSamplerState(&description, &mbi.samplers[mode])
		ensure(win.SUCCEEDED(result), "Create SamplerState Failed")
	}
}

@(private)
destroy_states :: proc() {
	for state in mbi.depth_states do state->Release()
	for state in mbi.blend_states do state->Release()
	for state in mbi.rasterizer_states do state->Release()
	for state in mbi.samplers do state->Release()
}

@(private)
set_render_state :: proc(depth:Depth_Mode, blend:Blend_Mode, cull:Cull_Mode) {
	blend_factor := [4]f32{0, 0, 0, 0}

	mbi.device_context->OMSetDepthStencilState(mbi.depth_states[depth], 0)
	mbi.device_context->OMSetBlendState(mbi.blend_states[blend], &blend_factor, 0xFFFFFFFF)
	mbi.device_context->RSSetState(mbi.rasterizer_states[cull])
}

@(private)
create_constant_buffer :: proc(size:u32) -> (buffer:^d3d11.IBuffer) {
	description := d3d11.BUFFER_DESC {
		ByteWidth = size,
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}

	result := mbi.device->CreateBuffer(&description, nil, &buffer)
	ensure(win.SUCCEEDED(result), "Create ConstantBuffer Failed")
	return
}

/*Copies data into a dynamic buffer*/
@(private)
update_buffer :: proc(buffer:^d3d11.IBuffer, data:rawptr, size:int) {
	mapped:d3d11.MAPPED_SUBRESOURCE
	result := mbi.device_context->Map(buffer, 0, .WRITE_DISCARD, {}, &mapped)
	ensure(win.SUCCEEDED(result), "Map buffer failed")
	mem.copy(mapped.pData, data, size)
	mbi.device_context->Unmap(buffer, 0)
}

/*Sets the combined view * projection matrix used by everything drawn until it is called again*/
@(private)
set_frame_constants :: proc(view_projection:matrix[4, 4]f32) {
	now:win.LARGE_INTEGER
	win.QueryPerformanceCounter(&now)
	seconds := f32(f64(now - mbi.timestamp.start_counter) / f64(mbi.timestamp.frequency))

	constants := Frame_Constants{view_projection = view_projection, time = seconds}
	if mbi.frame_constants != nil do update_buffer(mbi.frame_constants, &constants, size_of(Frame_Constants))
}

/*Sets a uniform the shader declares with `@(uniform)`, by its name. The value stays until it is set again.
`value` has the uniform's type: 0.5 for an f32, a [3]f32 for a [3]f32, a matrix[4, 4]f32 for a matrix, and a slice or
array with every element for an array uniform. A struct's field is named as in the shader: "key_light.strength"*/
set_shader_value :: proc(name:string, value:any) {
	ok, message := write_shader_value(&mbi.reflection, mbi.game_shadow, name, value)
	ensure(ok, message)
	mbi.game_dirty = true
}

/*Copies the game's uniforms to the GPU if one was set since the last draw*/
@(private)
upload_game_constants :: proc() {
	if mbi.game_dirty == false do return
	update_buffer(mbi.game_constants, raw_data(mbi.game_shadow), len(mbi.game_shadow))
	mbi.game_dirty = false
}

/*Sets the model matrix, tint, texture region and alpha cut-off used by the next draw*/
@(private)
set_render_constants :: proc(model:matrix[4, 4]f32, tint:[4]f32, uv_rectangle:[4]f32, alpha_cutoff:f32) {
	constants := Render_Constants{model = model, tint = tint, uv_rectangle = uv_rectangle, alpha_cutoff = alpha_cutoff}
	if mbi.render_constants != nil do update_buffer(mbi.render_constants, &constants, size_of(Render_Constants))
}

/*Starts a frame. Call once per frame before drawing anything*/
render_start :: proc() {
	if mbi.did_resize {
		mbi.device_context->OMSetRenderTargets(0, nil, nil)
		mbi.framebuffer_view->Release()
		mbi.framebuffer->Release()
		destroy_depth_buffer()

		result := mbi.swapchain->ResizeBuffers(0, 0, 0, .UNKNOWN, {})
		ensure(win.SUCCEEDED(result), "Swapchain buffer resize failed")

		result = mbi.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&mbi.framebuffer))

		result  = mbi.device->CreateRenderTargetView(mbi.framebuffer, nil, &mbi.framebuffer_view)
		ensure(win.SUCCEEDED(result), "Create RenderTargetView failed")

		create_depth_buffer()

		mbi.did_resize = false
	}

	viewport := d3d11.VIEWPORT {
		TopLeftX = 0,
		TopLeftY = 0,
		Width    = cast(f32)mbi.window_size[0],
		Height   = cast(f32)mbi.window_size[1],
		MinDepth = 0,
		MaxDepth = 1,
	}

	mbi.device_context->RSSetViewports(1, &viewport)
	mbi.device_context->OMSetRenderTargets(1, &mbi.framebuffer_view, mbi.depth_view)
	mbi.device_context->ClearDepthStencilView(mbi.depth_view, {.DEPTH}, 1.0, 0)

	set_render_state(.OPAQUE, .NONE, .BACK)
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	ensure(mbi.camera_active == false, "camera_end was not called before render_end")
	mbi.swapchain->Present(1, {})
}

/*Fills the whole window with `color`*/
clear_background :: proc(color:[4]f32) {
	color := color
	mbi.device_context->ClearRenderTargetView(mbi.framebuffer_view, &color)
}

@(private)
create_depth_buffer :: proc() {
	framebuffer_description:d3d11.TEXTURE2D_DESC
	mbi.framebuffer->GetDesc(&framebuffer_description)

	depth_description := d3d11.TEXTURE2D_DESC {
		Width = framebuffer_description.Width,
		Height = framebuffer_description.Height,
		MipLevels = 1,
		ArraySize = 1,
		Format = .D32_FLOAT,
		SampleDesc = {Count = 1},
		Usage = .DEFAULT,
		BindFlags = {.DEPTH_STENCIL},
	}


	result := mbi.device->CreateTexture2D(&depth_description, nil, &mbi.depth_texture)
	ensure(win.SUCCEEDED(result), "Create depth texture failed")

	result = mbi.device->CreateDepthStencilView(mbi.depth_texture, nil, &mbi.depth_view)
	ensure(win.SUCCEEDED(result), "Create DepthStencilView failed")
}

@(private)
destroy_depth_buffer :: proc() {
	mbi.depth_view->Release()
	mbi.depth_texture->Release()
}

@(private)
compile_shader :: proc(entry_point:cstring, target:cstring, blob:^^d3d11.IBlob) {
	errors: ^d3d11.IBlob

	result := d3d_compiler.Compile(
		pSrcData = raw_data(mbi.shader_src),
		SrcDataSize = uint(len(mbi.shader_src)),
		pSourceName = "shaders/mesh.pc.hlsl", // for debug messages
		pDefines = nil,
		pInclude = nil,
		pEntrypoint = entry_point,
		pTarget = target,
		Flags1 = 0,
		Flags2 = 0,
		ppCode = blob,
		ppErrorMsgs = &errors,
	)

	if errors != nil {
		print(string(cstring(errors->GetBufferPointer())))
		errors->Release()
	}

	ensure(win.SUCCEEDED(result), "Shader Compilation failed")
}

/*Compiles the shaders and creates the input layout, constant buffers and render states*/
@(private)
create_pipeline :: proc() {
	// Generated by mbsc from shaders/mesh.mbs; see tools/mbsc and docs/shader_hlsl.md
	mbi.shader_src = #load("shaders/mesh.pc.hlsl")

	// ...together with its reflection file, which says where everything the shader needs is bound
	reflection_ok:bool
	reflection_message:string
	mbi.reflection, reflection_ok, reflection_message = parse_reflection(#load("shaders/mesh.pc.refl", string))
	ensure(reflection_ok, reflection_message)
	check_message := check_engine_blocks(&mbi.reflection)
	ensure(check_message == "", check_message)

	compile_shader("vertex_main", "vs_5_0", &mbi.vertex_shader_blob)
	compile_shader("fragment_main", "ps_5_0", &mbi.pixel_shader_blob)

	result := mbi.device->CreateVertexShader(
		pShaderBytecode = mbi.vertex_shader_blob->GetBufferPointer(),
		BytecodeLength = mbi.vertex_shader_blob->GetBufferSize(),
		pClassLinkage = nil,
		ppVertexShader = &mbi.vertex_shader,
	)

	ensure(win.SUCCEEDED(result), "Vertex shader creation failed")

	result = mbi.device->CreatePixelShader(
		pShaderBytecode = mbi.pixel_shader_blob->GetBufferPointer(),
		BytecodeLength = mbi.pixel_shader_blob->GetBufferSize(),
		pClassLinkage = nil,
		ppPixelShader = &mbi.pixel_shader,
	)
	ensure(win.SUCCEEDED(result), "Pixel shader creation failed")

	// The input layout is what the shader reads, each attribute found in the engine's Vertex
	input_element_descs := make([]d3d11.INPUT_ELEMENT_DESC, len(mbi.reflection.attributes), context.temp_allocator)
	for attribute, index in mbi.reflection.attributes {
		found, message := find_vertex_attribute(attribute)
		ensure(message == "", message)
		input_element_descs[index] = {
			SemanticName = strings.clone_to_cstring(attribute.name, context.temp_allocator),
			Format = found.format,
			AlignedByteOffset = found.offset,
			InputSlotClass = .VERTEX_DATA,
		}
	}

	result = mbi.device->CreateInputLayout(
		pInputElementDescs = raw_data(input_element_descs),
		NumElements = u32(len(input_element_descs)),
		pShaderBytecodeWithInputSignature = mbi.vertex_shader_blob->GetBufferPointer(),
		BytecodeLength = mbi.vertex_shader_blob->GetBufferSize(),
		ppInputLayout = &mbi.input_layout,
	)

	ensure(win.SUCCEEDED(result), "Input layout creation failed")

	// The engine's blocks are the size of its structs (check_engine_blocks made sure the shader agrees); the game's
	// block is as big as the shader says, and starts out as zeros
	if mbi.reflection.blocks[.FRAME].present do mbi.frame_constants = create_constant_buffer(size_of(Frame_Constants))
	if mbi.reflection.blocks[.RENDER].present do mbi.render_constants = create_constant_buffer(size_of(Render_Constants))
	if mbi.reflection.blocks[.GAME].present {
		mbi.game_shadow = make([]byte, mbi.reflection.blocks[.GAME].size)
		mbi.game_constants = create_constant_buffer(u32(len(mbi.game_shadow)))
		mbi.game_dirty = true
	}

	create_states()
}

/*Everything drawn until camera_end is seen through this camera*/
camera_start :: proc(camera:Camera) {
	ensure(mbi.camera_active == false, "camera_start called again before camera_end")

	window :=[2]f32{f32(mbi.window_size[0]), f32(mbi.window_size[1])}
	aspect := calculate_window_aspect()

	// With pixel_snap, draw through a copy moved onto the pixel grid. render_sprite reads
	// pixel_scale to snap sprite edges the same way
	used := calculate_camera_snapped(camera, window)
	mbi.pixel_scale = calculate_camera_snap_scale(camera, window.y)

	mbi.view = calculate_camera_view_matrix(used) // render_mesh needs it to sort transparent items
	mbi.camera_active = true
	mbi.screen_pass = camera.screen

	// linalg builds OpenGL depth (-1..1); GL_TO_D3D_DEPTH converts it to D3D's 0..1
	view_projection := GL_TO_D3D_DEPTH * calculate_camera_projection_gl(used, aspect) * mbi.view
	set_frame_constants(view_projection)
}

/*Sorts and draws everything queued since camera_start*/
camera_end :: proc() {
	ensure(mbi.camera_active == true, "camera_end called without camera_start")

	// A hidden pass was queued but is never drawn
	if mbi.discard_pass == true {
		clear(&mbi.opaque_items)
		clear(&mbi.transparent_items)
		mbi.camera_active = false
		mbi.screen_pass = false
		mbi.discard_pass = false
		return
	}

	// A screen camera has no depth buffer to lean on, so what is drawn last lands on top
	depth_opaque := Depth_Mode.OPAQUE
	depth_transparent := Depth_Mode.TRANSPARENT
	if mbi.screen_pass == true {
		depth_opaque = .DISABLED
		depth_transparent = .DISABLED
	}

	// Opaque items: group them by mesh so the same buffers are bound back to back.
	// A stable sort keeps submission order for equal items. A screen pass skips it:
	// with depth off, submission order is the paint order
	if mbi.screen_pass == false {
		slice.stable_sort_by(mbi.opaque_items[:], proc(a, b:Render_Item) -> bool {
			if a.texture.view != b.texture.view {
				return uintptr(a.texture.view) < uintptr(b.texture.view)
			}
			return uintptr(a.mesh.vertex_buffer) < uintptr(b.mesh.vertex_buffer)
		})
	}

	// Transparent items: farthest first, so nearer ones blend over farther ones
	slice.stable_sort_by(mbi.transparent_items[:], proc(a, b:Render_Item) -> bool {
		return a.depth > b.depth
	})

	for item in mbi.opaque_items {
		set_render_state(depth_opaque, .NONE, item.cull)
		render_item(item)
	}

	for item in mbi.transparent_items {
		set_render_state(depth_transparent, .ALPHA, item.cull)
		render_item(item)
	}

	clear(&mbi.opaque_items)
	clear(&mbi.transparent_items)
	mbi.camera_active = false
	mbi.screen_pass = false
}

@(private)
destroy_pipeline :: proc() {
	delete(mbi.opaque_items)
	delete(mbi.transparent_items)

	if mbi.game_constants != nil do mbi.game_constants->Release()
	if mbi.render_constants != nil do mbi.render_constants->Release()
	if mbi.frame_constants != nil do mbi.frame_constants->Release()
	delete(mbi.game_shadow)
	destroy_reflection(&mbi.reflection)

	destroy_states()

	mbi.input_layout->Release()
	mbi.pixel_shader_blob->Release()
	mbi.pixel_shader->Release()
	mbi.vertex_shader_blob->Release()
	mbi.vertex_shader->Release()
}
