#+build windows

package matchbox

/*
	Render
	======
	Handles the rendering

	PC (D3D11). Everything drawn is 3D; 2D is an orthographic camera.
	The 3D path is added in Phase B (see render_plan.md).
*/

import win "core:sys/windows"
import "core:mem"
import "core:math/linalg"
import "core:slice"

import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

Frame_Constants :: struct {
	view_projection:matrix[4,4]f32,
}

Draw_Constants :: struct {
	model:matrix[4,4]f32,
	tint:[4]f32,
	uv_rect:[4]f32,
	alpha_cutoff:f32,
	_pad:[3]f32
}

// D3D constant buffers must be a multiple of 16 bytes
#assert(size_of(Frame_Constants) % 16 == 0)
#assert(size_of(Draw_Constants) % 16 == 0)

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

Blend_Mode :: enum {
	NONE,
	ALPHA,
}

Cull_Mode :: enum {
	BACK, // Skips triangles not facing the camera
	NONE, // Draws all triangles of a sprite and two-sided quads
}

// Geometry on the GPU. `create_mesh` makes one, `destroy_mesh` frees it.
Mesh :: struct {
	vertex_buffer:^d3d11.IBuffer,
	index_buffer:^d3d11.IBuffer,
	index_count:u32,
}

Draw_Item :: struct {
	mesh:Mesh,
	model:matrix[4,4]f32,
	tint:[4]f32,
	cull:Cull_Mode,
	depth:f32,
	texture:Texture,
	uv_rect:[4]f32,
	alpha_cutoff:f32,
}

/*Copies vertices and indices to the GPU. The slices can be freed afterwards*/
create_mesh :: proc(vertices:[]Vertex, indices:[]u16) -> (mesh:Mesh) {
	assert(len(vertices) > 0 && len(indices) > 0, "A mesh needs vertices and indices")
	assert(len(vertices) <= 65536, "A mesh with 16-bit indices can have at most 65536 vertices")

	vertex_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertices) * size_of(Vertex)),
		Usage = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vertex_data := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(vertices)}

	res := mbi.device->CreateBuffer(&vertex_desc, &vertex_data, &mesh.vertex_buffer)
	ensure(win.SUCCEEDED(res), "Create mesh vertex buffer failed")

	index_desc := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(indices) * size_of(u16)),
		Usage = .IMMUTABLE,
		BindFlags = {.INDEX_BUFFER},
	}
	index_data := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(indices)}

	res = mbi.device->CreateBuffer(&index_desc, &index_data, &mesh.index_buffer)
	ensure(win.SUCCEEDED(res), "Create mesh index buffer failed")

	mesh.index_count = u32(len(indices))
	return
}

destroy_mesh :: proc(mesh:Mesh) {
	if mesh.index_buffer != nil do mesh.index_buffer->Release()
	if mesh.vertex_buffer != nil do mesh.vertex_buffer->Release()
}

render_mesh :: proc(mesh:Mesh, model:matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY, tint:[4]f32 = {1, 1, 1, 1},blend:Blend_Mode = .NONE, cull:Cull_Mode = .BACK, texture:Texture = {}) {

	queue_draw(mesh, model, tint, blend, cull, texture, {0,0, 1,1}, 0)
}

@(private)
queue_draw :: proc(mesh:Mesh, model:matrix[4,4]f32, tint:[4]f32, blend:Blend_Mode, cull:Cull_Mode, texture:Texture, uv_rect:[4]f32, alpha_cutoff:f32) {

	ensure(mbi.camera_active, "render_mesh must be called between camera_start and camera_end")

	item := Draw_Item{mesh = mesh, model = model, tint = tint, cull = cull, texture = texture, uv_rect = uv_rect, alpha_cutoff = alpha_cutoff}

	switch blend {
	case .NONE:
		append(&mbi.opaque_items, item)

	case .ALPHA:
		// Where the model's origin is in view space. The camera looks down -Z,
		// so things in front of it have a negative z; flip it so bigger = farther
		view_position := mbi.view * model * [4]f32{0, 0, 0, 1}
		item.depth = -view_position.z
		append(&mbi.transparent_items, item)
	}
}



@(private)
draw_item :: proc(item:Draw_Item) {

	set_draw_constants(item.model, item.tint, item.uv_rect, item.alpha_cutoff)

	vertex_buffer := item.mesh.vertex_buffer
	stride:u32 = size_of(Vertex)
	offset:u32 = 0

	constant_buffers := [2]^d3d11.IBuffer{mbi.frame_constants, mbi.draw_constants}

	mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	mbi.device_context->IASetInputLayout(mbi.input_layout)
	mbi.device_context->IASetVertexBuffers(0, 1, &vertex_buffer, &stride, &offset)
	mbi.device_context->IASetIndexBuffer(item.mesh.index_buffer, .R16_UINT, 0)

	mbi.device_context->VSSetShader(mbi.vertex_shader, nil, 0)
	mbi.device_context->VSSetConstantBuffers(0, 2, &constant_buffers[0])

	mbi.device_context->VSSetConstantBuffers(0, 2, &constant_buffers[0])
	mbi.device_context->PSSetConstantBuffers(0, 2, &constant_buffers[0])
	
	mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)

	texture_view := item.texture.view
	if texture_view == nil do texture_view = mbi.white_texture_view

	mbi.device_context->PSSetShaderResources(0, 1, &texture_view)
	mbi.device_context->PSSetSamplers(0, 1, &mbi.samplers[item.texture.filter])
	

	mbi.device_context->DrawIndexed(item.mesh.index_count, 0, 0)
}

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

	for &desc, mode in depth_descs {
		res := mbi.device->CreateDepthStencilState(&desc, &mbi.depth_states[mode])
		ensure(win.SUCCEEDED(res), "Create DepthStencilState Failed")
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

	for &desc, mode in blend_descs {
		res := mbi.device->CreateBlendState(&desc, &mbi.blend_states[mode])
		ensure(win.SUCCEEDED(res), "Create BlendState Failed")
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

	for &desc, mode in rasterizer_descs {
		res := mbi.device->CreateRasterizerState(&desc, &mbi.rasterizer_states[mode])
		ensure(win.SUCCEEDED(res), "Create RasterizerState Failed")
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

	for &desc, mode in sampler_descs {
		res := mbi.device->CreateSamplerState(&desc, &mbi.samplers[mode])
		ensure(win.SUCCEEDED(res), "Create SamplerState Failed")
	}	
}


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
	mbi.device_context->OMSetBlendState(mbi.blend_states[blend], &blend_factor,	0xFFFFFFFF)
	mbi.device_context->RSSetState(mbi.rasterizer_states[cull])

}


create_constant_buffer :: proc(size:u32) -> (buffer:^d3d11.IBuffer) {
	desc := d3d11.BUFFER_DESC {
		ByteWidth = size,
		Usage = .DYNAMIC,
		BindFlags = {.CONSTANT_BUFFER},
		CPUAccessFlags = {.WRITE},
	}

	res := mbi.device->CreateBuffer(&desc, nil, &buffer)
	ensure(win.SUCCEEDED(res), "Create ConstantBuffer Failed")
	return
}

/*Copies data into a dynamic buffer*/
update_buffer :: proc(buffer:^d3d11.IBuffer, data:rawptr, size:int) {
	mapped:d3d11.MAPPED_SUBRESOURCE
	res := mbi.device_context->Map(buffer, 0, .WRITE_DISCARD, {}, &mapped)
	ensure(win.SUCCEEDED(res), "Map buffer failed")
	mem.copy(mapped.pData, data, size)
	mbi.device_context->Unmap(buffer, 0)
}

/*Sets the combined view * projection matrix used by everything drawn until it is called again*/
set_view_projection :: proc(view_projection:matrix[4, 4]f32) {
	constants := Frame_Constants{view_projection = view_projection}
	update_buffer(mbi.frame_constants, &constants, size_of(Frame_Constants))
}

/*Sets the model matrix and tint used by the next draw*/
set_draw_constants :: proc(model:matrix[4, 4]f32, tint:[4]f32, uv_rect:[4]f32, alpha_cutoff:f32) {
	constants := Draw_Constants{model = model, tint = tint, uv_rect = uv_rect, alpha_cutoff = alpha_cutoff}
	update_buffer(mbi.draw_constants, &constants, size_of(Draw_Constants))
}

render_start :: proc() {
	if mbi.did_resize {
		
		mbi.device_context->OMSetRenderTargets(0, nil, nil)
		mbi.framebuffer_view->Release()
		mbi.framebuffer->Release()
		destroy_depth_buffer()

		res := mbi.swapchain->ResizeBuffers(0, 0, 0, .UNKNOWN, {})
		ensure(win.SUCCEEDED(res), "Swapchain buffer resize failed")

		res = mbi.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&mbi.framebuffer))

		res  = mbi.device->CreateRenderTargetView(mbi.framebuffer, nil, &mbi.framebuffer_view)
		ensure(win.SUCCEEDED(res), "Create RenderTargetView failed")

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

	// blend_factor := [4]f32{0, 0, 0, 0}
	// mbi.device_context->OMSetBlendState(mbi.blend_state, &blend_factor, 0xFFFFFFFF)

	mbi.device_context->RSSetViewports(1, &viewport)
	// mbi.device_context->RSSetState(mbi.rasterizer_state)
	mbi.device_context->OMSetRenderTargets(1, &mbi.framebuffer_view, mbi.depth_view)
	mbi.device_context->ClearDepthStencilView(mbi.depth_view, {.DEPTH}, 1.0, 0)

	set_render_state(.OPAQUE, .NONE, .BACK)
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	ensure(mbi.camera_active == false, "end was not called before render_end")
	mbi.swapchain->Present(1, {})
}

clear_background :: proc(color:[4]f32) {
	color := color
	mbi.device_context->ClearRenderTargetView(mbi.framebuffer_view, &color)
}


create_depth_buffer :: proc() {
	framebuffer_desc:d3d11.TEXTURE2D_DESC
	mbi.framebuffer->GetDesc(&framebuffer_desc)

	depth_desc := d3d11.TEXTURE2D_DESC {
		Width = framebuffer_desc.Width,
		Height = framebuffer_desc.Height,
		MipLevels = 1,
		ArraySize = 1,
		Format = .D32_FLOAT,
		SampleDesc = {Count = 1},
		Usage = .DEFAULT,
		BindFlags = {.DEPTH_STENCIL},
	}


	res := mbi.device->CreateTexture2D(&depth_desc, nil, &mbi.depth_texture)
	ensure(win.SUCCEEDED(res), "Create depth texture failed")

	res = mbi.device->CreateDepthStencilView(mbi.depth_texture, nil, &mbi.depth_view)
	ensure(win.SUCCEEDED(res), "Create DepthStencilView failed")
	
}

destroy_depth_buffer :: proc() {
	mbi.depth_view->Release()
	mbi.depth_texture->Release()
}

compile_shader :: proc(entry_point:cstring, target:cstring, blob:^^d3d11.IBlob) {
	errors: ^d3d11.IBlob

	res := d3d_compiler.Compile(
		pSrcData = raw_data(mbi.shader_src),
		SrcDataSize = uint(len(mbi.shader_src)),
		pSourceName = "shaders/mesh.hlsl", // for debug messages
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


	ensure(win.SUCCEEDED(res), "Shader Compilation failed")
}

create_pipeline :: proc() {
	mbi.shader_src = #load("shaders/mesh.hlsl")

	compile_shader("vertex_main", "vs_5_0", &mbi.vertex_shader_blob)
	compile_shader("pixel_main", "ps_5_0", &mbi.pixel_shader_blob)

	res := mbi.device->CreateVertexShader(
		pShaderBytecode = mbi.vertex_shader_blob->GetBufferPointer(),
		BytecodeLength = mbi.vertex_shader_blob->GetBufferSize(),
		pClassLinkage = nil,
		ppVertexShader = &mbi.vertex_shader,
	)

	ensure(win.SUCCEEDED(res), "Vertex shader creation failed")


	res = mbi.device->CreatePixelShader(
		pShaderBytecode = mbi.pixel_shader_blob->GetBufferPointer(),
		BytecodeLength = mbi.pixel_shader_blob->GetBufferSize(),
		pClassLinkage = nil,
		ppPixelShader = &mbi.pixel_shader,
	)
	ensure(win.SUCCEEDED(res), "Pixel shader creation failed")

	input_element_descs := []d3d11.INPUT_ELEMENT_DESC {
		{
			SemanticName = "position",
			Format = .R32G32B32_FLOAT,
			AlignedByteOffset = 0,
			InputSlotClass = .VERTEX_DATA,
		},
		{
			SemanticName = "texcoord",
			Format = .R32G32_FLOAT,
			AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
			InputSlotClass = .VERTEX_DATA,
		},
		{
			SemanticName = "color",
			Format = .R32G32B32A32_FLOAT,
			AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
			InputSlotClass = .VERTEX_DATA,
		},
	}

	res = mbi.device->CreateInputLayout(
		pInputElementDescs = raw_data(input_element_descs),
		NumElements = u32(len(input_element_descs)),
		pShaderBytecodeWithInputSignature = mbi.vertex_shader_blob->GetBufferPointer(),
		BytecodeLength = mbi.vertex_shader_blob->GetBufferSize(),
		ppInputLayout = &mbi.input_layout,
	)

	ensure(win.SUCCEEDED(res), "Input layout creation failed")


	mbi.frame_constants = create_constant_buffer(size_of(Frame_Constants))
	mbi.draw_constants = create_constant_buffer(size_of(Draw_Constants))

	create_states()
	
}


/*Everything drawn until camera_end is seen through this camera*/


/*Everything drawn until camera_end is seen through this camera*/
camera_start :: proc(cam:Camera) {
	ensure(mbi.camera_active == false, "camera_start called again before camera_end")


	window := [2]f32{f32(mbi.window_size[0]), f32(mbi.window_size[1])}

	aspect:f32 = 1
	if window.y > 0 {
		aspect = window.x / window.y
	}

	// With pixel_snap, draw through a copy moved onto the pixel grid. render_sprite reads
	// pixel_scale to snap sprite edges the same way
	used := camera_snapped(cam, window)
	mbi.pixel_scale = camera_snap_scale(cam, window.y)

	mbi.view = camera_view_matrix(used) // render_mesh needs it to sort transparent items
	mbi.camera_active = true

	// linalg builds OpenGL depth (-1..1); GL_TO_D3D_DEPTH converts it to D3D's 0..1
	view_projection := GL_TO_D3D_DEPTH * camera_projection_gl(used, aspect) * mbi.view
	set_frame_constants(view_projection)

	// aspect:f32 = 1
	// if mbi.window_size[1] > 0 {
	// 	aspect = f32(mbi.window_size[0]) / f32(mbi.window_size[1])
	// }

	// mbi.view = camera_view_matrix(cam) // render_mesh needs it to sort transparent items
	// mbi.camera_active = true

	// // linalg builds OpenGL depth (-1..1); GL_TO_D3D_DEPTH converts it to D3D's 0..1
	// view_projection := GL_TO_D3D_DEPTH * camera_projection_gl(cam, aspect) * mbi.view
	// set_frame_constants(view_projection)
}

/*Sorts and draws everything queued since camera_start*/
camera_end :: proc() {
	ensure(mbi.camera_active == true, "camera_end called without camera_start")

	// Opaque items: group them by mesh so the same buffers are bound back to back.
	// A stable sort keeps submission order for equal items
	slice.stable_sort_by(mbi.opaque_items[:], proc(a, b:Draw_Item) -> bool {
		if a.texture.view != b.texture.view {
			return uintptr(a.texture.view) < uintptr(b.texture.view)
		}
		return uintptr(a.mesh.vertex_buffer) < uintptr(b.mesh.vertex_buffer)
	})

	// Transparent items: farthest first, so nearer ones blend over farther ones
	slice.stable_sort_by(mbi.transparent_items[:], proc(a, b:Draw_Item) -> bool {
		return a.depth > b.depth
	})

	for item in mbi.opaque_items {
		set_render_state(.OPAQUE, .NONE, item.cull)
		draw_item(item)
	}

	for item in mbi.transparent_items {
		set_render_state(.TRANSPARENT, .ALPHA, item.cull)
		draw_item(item)
	}

	clear(&mbi.opaque_items)
	clear(&mbi.transparent_items)
	mbi.camera_active = false
}

destroy_pipeline :: proc() {

	delete(mbi.opaque_items)
	delete(mbi.transparent_items)

	mbi.draw_constants->Release()
	mbi.frame_constants->Release()
	
	destroy_states()

	
	mbi.input_layout->Release()
	mbi.pixel_shader_blob->Release()
	mbi.pixel_shader->Release()
	mbi.vertex_shader_blob->Release()
	mbi.vertex_shader->Release()
}

// Private fields
@(private)
set_frame_constants :: proc(view_projection:matrix[4, 4]f32) {
	constants := Frame_Constants{view_projection = view_projection}
	update_buffer(mbi.frame_constants, &constants, size_of(Frame_Constants))
}
