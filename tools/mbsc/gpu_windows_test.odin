package mbsc

import "core:fmt"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

// A small renderer for the tests: it draws one mesh with a pair of HLSL entry points through Direct3D 11's software
// device (WARP), so it needs no GPU, and gives back the pixels as floats. It follows the engine's pipeline:
// the same input layout, constant buffers at b0 (frame), b1 (render) and b2 (the game's uniforms), a texture at t0
// and a sampler at s0. Blending and depth are off, so the result is exactly what the pixel shader returns.

// What the renderer puts in a pixel the shader never wrote (a `discard`, or outside every triangle). It can't be a
// colour a shader returns, which makes it easy to see in a comparison.
UNWRITTEN :: f32(-1)

Gpu_Texture :: struct {
	width:  u32,
	height: u32,
	rgba:   []u8, // width * height * 4 bytes
	linear: bool, // linear filtering; otherwise nearest
}

Gpu_Job :: struct {
	hlsl:         string,
	vertex_entry: cstring,
	pixel_entry:  cstring,
	width:        u32,
	height:       u32,
	vertices:     []f32, // 9 floats a vertex: position (3), uv (2), color (4), as the engine's Vertex
	indices:      []u16,
	frame:        []f32, // the contents of the b0 buffer
	draw:         []f32, // b1
	game:         []f32, // b2
	texture:      Maybe(Gpu_Texture),
}

// compile_blob compiles one entry point; the caller releases the blob. `message` is the compiler's complaint.
compile_blob :: proc(source: string, entry: cstring, profile: cstring) -> (code: ^d3d11.IBlob, message: string) {
	errors: ^d3d11.IBlob
	result := d3d_compiler.Compile(
		pSrcData = raw_data(source),
		SrcDataSize = uint(len(source)),
		pSourceName = "gpu_test.hlsl",
		pDefines = nil,
		pInclude = nil,
		pEntrypoint = entry,
		pTarget = profile,
		Flags1 = 0,
		Flags2 = 0,
		ppCode = &code,
		ppErrorMsgs = &errors,
	)
	if errors != nil {
		message = fmt.aprintf("%s", cstring(errors->GetBufferPointer()), allocator = context.temp_allocator)
		errors->Release()
	}
	if result < 0 {
		if message == "" {
			message = fmt.aprintf("the compiler failed with code %x", u32(result), allocator = context.temp_allocator)
		}
		if code != nil {
			code->Release()
			code = nil
		}
	}
	return
}

// padded_constants copies floats into a buffer whose size is a multiple of 16 bytes and at least 16, as
// Direct3D requires of a constant buffer.
@(private = "file")
padded_constants :: proc(values: []f32) -> []f32 {
	count := max((len(values) + 3) / 4 * 4, 4)
	result := make([]f32, count, context.temp_allocator)
	copy(result, values)
	return result
}

@(private = "file")
make_buffer :: proc(device: ^d3d11.IDevice, data: rawptr, size: u32, bind: d3d11.BIND_FLAGS) -> ^d3d11.IBuffer {
	desc := d3d11.BUFFER_DESC {
		ByteWidth = size,
		Usage     = .DEFAULT,
		BindFlags = bind,
	}
	initial := d3d11.SUBRESOURCE_DATA {
		pSysMem = data,
	}
	buffer: ^d3d11.IBuffer
	result := device->CreateBuffer(&desc, &initial, &buffer)
	if win.SUCCEEDED(result) == false {
		return nil
	}
	return buffer
}

// gpu_render draws the job and returns width * height * 4 floats (RGBA, row by row, top row first). When it can't,
// `message` says why and `pixels` is empty.
gpu_render :: proc(job: Gpu_Job) -> (pixels: []f32, message: string) {
	device: ^d3d11.IDevice
	context_: ^d3d11.IDeviceContext
	result := d3d11.CreateDevice(nil, .WARP, nil, {}, nil, 0, d3d11.SDK_VERSION, &device, nil, &context_)
	if win.SUCCEEDED(result) == false {
		return nil, "can't create a Direct3D 11 software device"
	}
	defer device->Release()
	defer context_->Release()

	vertex_code, vertex_message := compile_blob(job.hlsl, job.vertex_entry, "vs_5_0")
	if vertex_code == nil {
		return nil, fmt.aprintf("vertex shader: %s", vertex_message, allocator = context.temp_allocator)
	}
	defer vertex_code->Release()
	pixel_code, pixel_message := compile_blob(job.hlsl, job.pixel_entry, "ps_5_0")
	if pixel_code == nil {
		return nil, fmt.aprintf("pixel shader: %s", pixel_message, allocator = context.temp_allocator)
	}
	defer pixel_code->Release()

	vertex_shader: ^d3d11.IVertexShader
	pixel_shader: ^d3d11.IPixelShader
	device->CreateVertexShader(vertex_code->GetBufferPointer(), vertex_code->GetBufferSize(), nil, &vertex_shader)
	device->CreatePixelShader(pixel_code->GetBufferPointer(), pixel_code->GetBufferSize(), nil, &pixel_shader)
	if vertex_shader == nil || pixel_shader == nil {
		return nil, "can't create the shaders"
	}
	defer vertex_shader->Release()
	defer pixel_shader->Release()

	// the engine's input layout (create_pipeline in render_windows.odin)
	elements := []d3d11.INPUT_ELEMENT_DESC {
		{SemanticName = "position", Format = .R32G32B32_FLOAT, AlignedByteOffset = 0, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "texcoord", Format = .R32G32_FLOAT, AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT, InputSlotClass = .VERTEX_DATA},
		{SemanticName = "color", Format = .R32G32B32A32_FLOAT, AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT, InputSlotClass = .VERTEX_DATA},
	}
	layout: ^d3d11.IInputLayout
	result = device->CreateInputLayout(raw_data(elements), u32(len(elements)), vertex_code->GetBufferPointer(), vertex_code->GetBufferSize(), &layout)
	if win.SUCCEEDED(result) == false {
		return nil, "the vertex shader doesn't take the engine's vertex layout (position, texcoord, color)"
	}
	defer layout->Release()

	vertex_buffer := make_buffer(device, raw_data(job.vertices), u32(len(job.vertices) * size_of(f32)), {.VERTEX_BUFFER})
	index_buffer := make_buffer(device, raw_data(job.indices), u32(len(job.indices) * size_of(u16)), {.INDEX_BUFFER})
	if vertex_buffer == nil || index_buffer == nil {
		return nil, "can't create the mesh buffers"
	}
	defer vertex_buffer->Release()
	defer index_buffer->Release()

	constants: [3]^d3d11.IBuffer
	contents := [3][]f32{padded_constants(job.frame), padded_constants(job.draw), padded_constants(job.game)}
	for values, slot in contents {
		constants[slot] = make_buffer(device, raw_data(values), u32(len(values) * size_of(f32)), {.CONSTANT_BUFFER})
		if constants[slot] == nil {
			return nil, "can't create a constant buffer"
		}
	}
	defer for buffer in constants {
		buffer->Release()
	}

	// the texture, when there is one
	texture_view: ^d3d11.IShaderResourceView
	sampler: ^d3d11.ISamplerState
	if input, has_texture := job.texture.?; has_texture {
		texture_desc := d3d11.TEXTURE2D_DESC {
			Width      = input.width,
			Height     = input.height,
			MipLevels  = 1,
			ArraySize  = 1,
			Format     = .R8G8B8A8_UNORM,
			Usage      = .IMMUTABLE,
			BindFlags  = {.SHADER_RESOURCE},
			SampleDesc = {Count = 1},
		}
		texture_data := d3d11.SUBRESOURCE_DATA {
			pSysMem     = raw_data(input.rgba),
			SysMemPitch = input.width * 4,
		}
		texture: ^d3d11.ITexture2D
		if win.SUCCEEDED(device->CreateTexture2D(&texture_desc, &texture_data, &texture)) == false {
			return nil, "can't create the texture"
		}
		defer texture->Release()
		device->CreateShaderResourceView(texture, nil, &texture_view)

		sampler_desc := d3d11.SAMPLER_DESC {
			Filter         = .MIN_MAG_MIP_LINEAR if input.linear else .MIN_MAG_MIP_POINT,
			AddressU       = .CLAMP,
			AddressV       = .CLAMP,
			AddressW       = .CLAMP,
			ComparisonFunc = .NEVER,
			MaxLOD         = d3d11.FLOAT32_MAX,
		}
		device->CreateSamplerState(&sampler_desc, &sampler)
	}
	defer if texture_view != nil {
		texture_view->Release()
	}
	defer if sampler != nil {
		sampler->Release()
	}

	// the target: 32-bit floats, so nothing is rounded
	target_desc := d3d11.TEXTURE2D_DESC {
		Width      = job.width,
		Height     = job.height,
		MipLevels  = 1,
		ArraySize  = 1,
		Format     = .R32G32B32A32_FLOAT,
		Usage      = .DEFAULT,
		BindFlags  = {.RENDER_TARGET},
		SampleDesc = {Count = 1},
	}
	target: ^d3d11.ITexture2D
	if win.SUCCEEDED(device->CreateTexture2D(&target_desc, nil, &target)) == false {
		return nil, "can't create the render target"
	}
	defer target->Release()
	target_view: ^d3d11.IRenderTargetView
	device->CreateRenderTargetView(target, nil, &target_view)
	if target_view == nil {
		return nil, "can't create the render target view"
	}
	defer target_view->Release()

	raster_desc := d3d11.RASTERIZER_DESC {
		FillMode        = .SOLID,
		CullMode        = .NONE,
		DepthClipEnable = true,
	}
	raster: ^d3d11.IRasterizerState
	device->CreateRasterizerState(&raster_desc, &raster)
	defer if raster != nil {
		raster->Release()
	}

	clear_color := [4]f32{UNWRITTEN, UNWRITTEN, UNWRITTEN, UNWRITTEN}
	context_->ClearRenderTargetView(target_view, &clear_color)
	view := target_view
	context_->OMSetRenderTargets(1, &view, nil)
	viewport := d3d11.VIEWPORT {
		Width    = f32(job.width),
		Height   = f32(job.height),
		MaxDepth = 1,
	}
	context_->RSSetViewports(1, &viewport)
	context_->RSSetState(raster)

	stride: u32 = 9 * size_of(f32)
	offset: u32 = 0
	vertex_buffer_ptr := vertex_buffer
	context_->IASetPrimitiveTopology(.TRIANGLELIST)
	context_->IASetInputLayout(layout)
	context_->IASetVertexBuffers(0, 1, &vertex_buffer_ptr, &stride, &offset)
	context_->IASetIndexBuffer(index_buffer, .R16_UINT, 0)
	context_->VSSetShader(vertex_shader, nil, 0)
	context_->PSSetShader(pixel_shader, nil, 0)
	context_->VSSetConstantBuffers(0, 3, &constants[0])
	context_->PSSetConstantBuffers(0, 3, &constants[0])
	if texture_view != nil {
		context_->PSSetShaderResources(0, 1, &texture_view)
		context_->PSSetSamplers(0, 1, &sampler)
	}
	context_->DrawIndexed(u32(len(job.indices)), 0, 0)

	// read the target back through a staging texture
	staging_desc := target_desc
	staging_desc.Usage = .STAGING
	staging_desc.BindFlags = {}
	staging_desc.CPUAccessFlags = {.READ}
	staging: ^d3d11.ITexture2D
	if win.SUCCEEDED(device->CreateTexture2D(&staging_desc, nil, &staging)) == false {
		return nil, "can't create the staging texture"
	}
	defer staging->Release()
	context_->CopyResource(staging, target)

	mapped: d3d11.MAPPED_SUBRESOURCE
	if win.SUCCEEDED(context_->Map(staging, 0, .READ, {}, &mapped)) == false {
		return nil, "can't read the render target"
	}
	defer context_->Unmap(staging, 0)

	pixels = make([]f32, int(job.width * job.height * 4), context.temp_allocator)
	for row in 0 ..< int(job.height) {
		source := ([^]f32)(rawptr(uintptr(mapped.pData) + uintptr(row) * uintptr(mapped.RowPitch)))
		copy(pixels[row * int(job.width) * 4:(row + 1) * int(job.width) * 4], source[:int(job.width) * 4])
	}
	return pixels, ""
}

// pixel_at is the RGBA of the pixel at column x, row y.
pixel_at :: proc(pixels: []f32, width: u32, x, y: int) -> [4]f32 {
	start := (y * int(width) + x) * 4
	return {pixels[start], pixels[start + 1], pixels[start + 2], pixels[start + 3]}
}
