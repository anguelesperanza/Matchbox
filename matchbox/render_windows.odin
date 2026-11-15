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

import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"


Vertex :: struct {
	position:[3]f32,
	uv:[2]f32,
	color:[4]f32,
}

Frame_Constants :: struct {
	view_projection:matrix[4,4]f32,
}

Draw_Constants :: struct {
	model:matrix[4,4]f32,
	tint:[4]f32,
}

// D3D constant buffers must be a multiple of 16 bytes
#assert(size_of(Frame_Constants) % 16 == 0)
#assert(size_of(Draw_Constants) % 16 == 0)


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
set_draw_constants :: proc(model:matrix[4, 4]f32, tint:[4]f32) {
	constants := Draw_Constants{model = model, tint = tint}
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

	blend_factor := [4]f32{0, 0, 0, 0}
	mbi.device_context->OMSetBlendState(mbi.blend_state, &blend_factor, 0xFFFFFFFF)

	mbi.device_context->RSSetViewports(1, &viewport)
	mbi.device_context->RSSetState(mbi.rasterizer_state)
	mbi.device_context->OMSetRenderTargets(1, &mbi.framebuffer_view, mbi.depth_view)
	mbi.device_context->ClearDepthStencilView(mbi.depth_view, {.DEPTH}, 1.0, 0)
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
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

	
	rasterizer_desc := d3d11.RASTERIZER_DESC {
		FillMode = .SOLID,
		CullMode = .BACK,
		FrontCounterClockwise = true,
		DepthClipEnable = true,
	}

	res = mbi.device->CreateRasterizerState(&rasterizer_desc, &mbi.rasterizer_state)
	ensure(win.SUCCEEDED(res), "Create RasterizerState Failed")


	create_test_triangle() // TEMPORARY

}

destroy_pipeline :: proc() {

	mbi.draw_constants->Release()
	mbi.frame_constants->Release()
	
	mbi.test_vertex_buffer->Release() // temporary
	mbi.rasterizer_state->Release()
	
	mbi.input_layout->Release()
	mbi.pixel_shader_blob->Release()
	mbi.pixel_shader->Release()
	mbi.vertex_shader_blob->Release()
	mbi.vertex_shader->Release()
}


// TEMPORARY test geometry, to prove the pipeline works. Replaced by Mesh in B6.
create_test_triangle :: proc() {
	// Counter-clockwise as seen from the front: top, bottom-left, bottom-right.
	// For now these are clip-space positions: x and y from -1 to 1, depth from 0 to 1.
	vertices := [3]Vertex {
		{position = { 0.0,  0.5, 0.5}, uv = {0.5, 0}, color = {1, 0, 0, 1}}, // top, red
		{position = {-0.5, -0.5, 0.5}, uv = {0, 1},   color = {0, 1, 0, 1}}, // bottom left, green
		{position = { 0.5, -0.5, 0.5}, uv = {1, 1},   color = {0, 0, 1, 1}}, // bottom right, blue
	}

	desc := d3d11.BUFFER_DESC {
		ByteWidth = size_of(vertices),
		Usage = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	data := d3d11.SUBRESOURCE_DATA{pSysMem = &vertices}

	res := mbi.device->CreateBuffer(&desc, &data, &mbi.test_vertex_buffer)
	ensure(win.SUCCEEDED(res), "Create test vertex buffer failed")
}

render_test_triangle :: proc(model:matrix[4,4]f32 = linalg.MATRIX4F32_IDENTITY, tint:[4]f32 = {1, 1, 1, 1}) {

	set_draw_constants(model, tint)
	
	stride:u32 = size_of(Vertex)
	offset:u32 = 0

	constant_buffers := [2]^d3d11.IBuffer{mbi.frame_constants, mbi.draw_constants}

	mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	mbi.device_context->IASetInputLayout(mbi.input_layout)
	mbi.device_context->IASetVertexBuffers(0, 1, &mbi.test_vertex_buffer, &stride, &offset)

	


	mbi.device_context->VSSetShader(mbi.vertex_shader, nil, 0)
	mbi.device_context->VSSetConstantBuffers(0, 2, &constant_buffers[0])
	mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)
	mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)
	mbi.device_context->PSSetShaderResources(0, 1, &mbi.white_texture_view)
	mbi.device_context->PSSetSamplers(0, 1, &mbi.sampler)

	mbi.device_context->Draw(3, 0)
}
