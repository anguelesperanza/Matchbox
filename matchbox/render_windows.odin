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
import "core:strings"

import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"

Frame_Constants :: struct {
	view_projection:matrix[4,4]f32,
	time:f32, // seconds; the shader language's frame.time. Not filled in yet, so it is 0
	_pad:[3]f32, // HLSL starts a matrix on a whole row of 16 bytes
	view:matrix[4,4]f32, // the camera's view alone: a lit shader's eye space, where the lights block's directions are
}

Render_Constants :: struct {
	model:matrix[4,4]f32,
	tint:[4]f32,
	uv_rectangle:[4]f32, // matched to mesh.mbs by name: renaming it means regenerating every shader, the Vita .gxp included
	alpha_cutoff:f32,
	shininess:f32, // the part's material, read by the light built-ins (G2 L3); zero until lighting fills it (L6)
	specular_strength:f32,
	_pad:[1]f32
}

// D3D constant buffers must be a multiple of 16 bytes
#assert(size_of(Frame_Constants) % 16 == 0)
#assert(size_of(Render_Constants) % 16 == 0)
#assert(size_of(Lights_Block) % 16 == 0)

/*
	One compiled shader and what it reads. PC has three, as the handhelds do: mbi.pipeline (mesh.mbs),
	mbi.lit_pipeline (mesh_lit.mbs, per pixel) and mbi.vertex_lit_pipeline (mesh_vertex_lit.mbs, per vertex).
	The constant buffers are shared, and each pipeline binds the ones its reflection lists, so the unlit shader
	never sees the lights block it doesn't declare
*/
Render_Pipeline :: struct {
	vertex_shader:^d3d11.IVertexShader,
	vertex_shader_blob:^d3d11.IBlob,
	pixel_shader:^d3d11.IPixelShader,
	pixel_shader_blob:^d3d11.IBlob,
	input_layout:^d3d11.IInputLayout,
	reflection:Shader_Reflection, // where everything the shader needs is bound, from its .pc.refl
}

// linalg builds OpenGL clip space (depth -1..1); D3D wants 0..1: z_new = 0.5 * z + 0.5 * w
GL_TO_D3D_DEPTH :: matrix[4, 4]f32 {
	1, 0, 0,   0,
	0, 1, 0,   0,
	0, 0, 0.5, 0.5,
	0, 0, 0,   1,
}




// Geometry on the GPU. `create_mesh` makes one, `destroy_mesh` frees it.
Mesh :: struct {
	vertex_buffer:^d3d11.IBuffer,
	index_buffer:^d3d11.IBuffer,
	index_count:u32,
	lit:bool, // made by create_lit_mesh: Lit_Vertex, 48 bytes a vertex, with normals
	skinned:bool, // made by create_skinned_mesh: Skinned_Vertex, 56 bytes a vertex, with joints and weights (also lit)
}


/*Copies vertices and indices to the GPU. The slices can be freed afterwards*/
create_mesh :: proc(vertices:[]Vertex, indices:[]u16) -> (mesh:Mesh) {
	return create_mesh_from_bytes(mem.slice_to_bytes(vertices), len(vertices), indices)
}

/*Copies vertices with normals and indices to the GPU, for a model part. The slices can be freed afterwards*/
create_lit_mesh :: proc(vertices:[]Lit_Vertex, indices:[]u16) -> (mesh:Mesh) {
	mesh = create_mesh_from_bytes(mem.slice_to_bytes(vertices), len(vertices), indices)
	mesh.lit = true
	return
}

/*Copies skinned vertices and indices to the GPU, for a skinned model part. The slices can be freed afterwards*/
create_skinned_mesh :: proc(vertices:[]Skinned_Vertex, indices:[]u16) -> (mesh:Mesh) {
	mesh = create_mesh_from_bytes(mem.slice_to_bytes(vertices), len(vertices), indices)
	mesh.lit = true
	mesh.skinned = true
	return
}

/*The three kinds of mesh differ only in how many bytes a vertex has; the buffers are made the same way*/
@(private = "file")
create_mesh_from_bytes :: proc(vertex_bytes:[]u8, vertex_count:int, indices:[]u16) -> (mesh:Mesh) {
	assert(vertex_count > 0 && len(indices) > 0, "A mesh needs vertices and indices")
	assert(vertex_count <= 65536, "A mesh with 16-bit indices can have at most 65536 vertices")

	vertex_description := d3d11.BUFFER_DESC {
		ByteWidth = u32(len(vertex_bytes)),
		Usage = .IMMUTABLE,
		BindFlags = {.VERTEX_BUFFER},
	}
	vertex_data := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(vertex_bytes)}

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



/*What render.odin's sort groups opaque items by: the texture, then the mesh, so the same
GPU objects are bound back to back*/
@(private)
calculate_render_item_sort_key :: proc(item:Render_Item) -> [2]uintptr {
	return {uintptr(item.texture.view), uintptr(item.mesh.vertex_buffer)}
}

/*Issues the draw call for one queued item. The render state is already set*/
@(private)
render_item :: proc(item:Render_Item) {
	// A lit mesh is shaded only while lighting is on. Off, it goes through the unlit shader like everything else,
	// as models drew before lighting existed: a Lit_Vertex starts with a whole Vertex, so the unlit input layout
	// reads it unchanged with the longer stride. A separate switch rather than "lit when there are lights", so a
	// scene whose lights are all removed goes dark instead of flipping back to unlit (light.odin)
	pipeline := &mbi.pipeline
	if item.mesh.skinned {
		// A skinned mesh is never unlit-shaded by the plain shader (it would draw the bind pose): lighting off picks the
		// skinned unlit one, and per-vertex lighting is drawn per pixel (see Backend_State)
		pipeline = &mbi.skinned_lit_pipeline if mbi.lighting.settings.enabled else &mbi.skinned_pipeline
		set_skin_constants(item)
	} else if item.mesh.lit && mbi.lighting.settings.enabled {
		switch get_lighting_mode(item.material) {
		case .PER_PIXEL:  pipeline = &mbi.lit_pipeline
		case .PER_VERTEX: pipeline = &mbi.vertex_lit_pipeline
		}
	}

	// A game shader replaces the built-in for the meshes it has a pipeline for (shader_windows.odin)
	game_buffer := mbi.game_constants
	if custom := choose_shader(item); custom != nil {
		pipeline = &custom.skinned if item.mesh.skinned else &custom.plain
		game_buffer = custom.game_constants
		upload_shader_constants(custom)
	}

	set_render_constants(item)

	vertex_buffer := item.mesh.vertex_buffer
	stride:u32 = size_of(Lit_Vertex) if item.mesh.lit else size_of(Vertex)
	if item.mesh.skinned do stride = size_of(Skinned_Vertex)
	offset:u32 = 0

	upload_game_constants()

	mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	mbi.device_context->IASetInputLayout(pipeline.input_layout)
	mbi.device_context->IASetVertexBuffers(0, 1, &vertex_buffer, &stride, &offset)
	mbi.device_context->IASetIndexBuffer(item.mesh.index_buffer, .R16_UINT, 0)

	mbi.device_context->VSSetShader(pipeline.vertex_shader, nil, 0)
	mbi.device_context->PSSetShader(pipeline.pixel_shader, nil, 0)

	// Each constant buffer goes to the register the shader's reflection file names
	buffers := [Block_Kind]^d3d11.IBuffer{.FRAME = mbi.frame_constants, .RENDER = mbi.render_constants, .GAME = game_buffer, .LIGHTS = mbi.lights_constants, .SKIN = mbi.skin_constants}
	for block, kind in pipeline.reflection.blocks {
		if block.present == false do continue
		buffer := buffers[kind]
		mbi.device_context->VSSetConstantBuffers(u32(block.register), 1, &buffer)
		mbi.device_context->PSSetConstantBuffers(u32(block.register), 1, &buffer)
	}

	// The draw's texture goes to the first texture the shader declares; any others get plain white, which leaves
	// the colour as it is when it is multiplied in
	for texture, index in pipeline.reflection.textures {
		texture_view := item.texture.view if index == 0 else nil
		if texture_view == nil do texture_view = mbi.white_texture_view
		mbi.device_context->PSSetShaderResources(u32(texture.slot), 1, &texture_view)
	}
	if pipeline.reflection.has_sampler {
		mbi.device_context->PSSetSamplers(u32(pipeline.reflection.sampler), 1, &mbi.samplers[item.texture.filter])
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
set_frame_constants :: proc(view_projection:matrix[4, 4]f32, view:matrix[4, 4]f32) {
	seconds := f32(get_time())

	constants := Frame_Constants{view_projection = view_projection, time = seconds, view = view}
	if mbi.frame_constants != nil do update_buffer(mbi.frame_constants, &constants, size_of(Frame_Constants))
}

/*Copies the game's uniforms to the GPU if one was set since the last draw*/
@(private)
upload_game_constants :: proc() {
	if mbi.game_dirty == false do return
	update_buffer(mbi.game_constants, raw_data(mbi.game_shadow), len(mbi.game_shadow))
	mbi.game_dirty = false
}

/*Sets the model matrix, tint, texture region, alpha cut-off and material used by the next draw*/
@(private)
set_render_constants :: proc(item:Render_Item) {
	constants := Render_Constants {
		model = item.model,
		tint = item.tint,
		uv_rectangle = item.uv_rectangle,
		alpha_cutoff = item.alpha_cutoff,
		shininess = item.material.shininess,
		specular_strength = item.material.specular_strength,
	}
	if mbi.render_constants != nil do update_buffer(mbi.render_constants, &constants, size_of(Render_Constants))
}

/*
	Fills the lights block for the camera being drawn: the lights' directions are in eye space, so they change with
	the view, once per camera rather than once per frame. Skipped while lighting is off, when nothing reads it
*/
@(private)
set_lights_constants :: proc() {
	if mbi.lights_constants == nil || mbi.lighting.settings.enabled == false do return
	block := calculate_lights_block(mbi.lighting, mbi.view)
	update_buffer(mbi.lights_constants, &block, size_of(Lights_Block))
}

/*Fills the skin block with the draw's joints: three row arrays, padded with the identity (skin.odin)*/
@(private)
set_skin_constants :: proc(item:Render_Item) {
	if mbi.skin_constants == nil do return
	rows := get_skin_rows(item)
	update_buffer(mbi.skin_constants, raw_data(rows), len(rows) * size_of([4]f32))
}

/*Only the 3DS measures the GPU's time (render_3ds_freestanding_arm32.odin); the PC answers {0, 0}*/
get_gpu_times :: proc() -> [2]f32 {
	return {}
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

	bind_screen()
	mbi.device_context->ClearDepthStencilView(mbi.depth_view, {.DEPTH}, 1.0, 0)
	begin_internal_frame() // a game with set_internal_resolution on draws into its target from here
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	ensure(mbi.camera_active == false, "camera_end was not called before render_end")
	ensure(mbi.render_target_state.is_active == false || mbi.render_target_state.internal_frame, "render_target_end was not called before render_end")
	end_internal_frame()
	mbi.swapchain->Present(1, {})
}

/*Fills the whole window with `color`*/
clear_background :: proc(color:[4]f32) {
	color := color
	view := mbi.framebuffer_view
	if mbi.render_target_state.is_active do view = mbi.render_target_state.active.color_view
	mbi.device_context->ClearRenderTargetView(view, &color)
}

/*Fills the screen itself, whatever target is being drawn to*/
@(private)
clear_screen :: proc(color:[4]f32) {
	color := color
	mbi.device_context->ClearRenderTargetView(mbi.framebuffer_view, &color)
}

/*The 1x1 white a draw with no texture samples, so the colour is its tint alone. Made by init, and by the pixel tests*/
@(private)
create_white_texture :: proc() {
	pixel := [4]u8{255, 255, 255, 255}

	description := d3d11.TEXTURE2D_DESC {
		Width = 1, Height = 1, MipLevels = 1, ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
		SampleDesc = {Count = 1},
	}
	data := d3d11.SUBRESOURCE_DATA{pSysMem = &pixel, SysMemPitch = 4}

	result := mbi.device->CreateTexture2D(&description, &data, &mbi.white_texture)
	ensure(win.SUCCEEDED(result), "Create white texture failed")
	result = mbi.device->CreateShaderResourceView(mbi.white_texture, nil, &mbi.white_texture_view)
	ensure(win.SUCCEEDED(result), "Create white texture view failed")
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
compile_shader :: proc(source:[]u8, name:cstring, entry_point:cstring, target:cstring, blob:^^d3d11.IBlob) {
	errors: ^d3d11.IBlob

	result := d3d_compiler.Compile(
		pSrcData = raw_data(source),
		SrcDataSize = uint(len(source)),
		pSourceName = name, // for debug messages
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

/*Compiles both shaders and creates the constant buffers and render states*/
@(private)
create_pipeline :: proc() {
	// Generated by mbsc from shaders/mesh.mbs, mesh_lit.mbs and mesh_vertex_lit.mbs; see tools/mbsc and
	// docs/shader_hlsl.md. Each comes with its reflection file, which says where everything the shader needs is bound
	mbi.pipeline = create_render_pipeline(#load("shaders/mesh.pc.hlsl"), #load("shaders/mesh.pc.refl", string), "shaders/mesh.pc.hlsl", lit = false)
	mbi.lit_pipeline = create_render_pipeline(#load("shaders/mesh_lit.pc.hlsl"), #load("shaders/mesh_lit.pc.refl", string), "shaders/mesh_lit.pc.hlsl", lit = true)
	mbi.vertex_lit_pipeline = create_render_pipeline(#load("shaders/mesh_vertex_lit.pc.hlsl"), #load("shaders/mesh_vertex_lit.pc.refl", string), "shaders/mesh_vertex_lit.pc.hlsl", lit = true)
	mbi.skinned_pipeline = create_render_pipeline(#load("shaders/mesh_skinned.pc.hlsl"), #load("shaders/mesh_skinned.pc.refl", string), "shaders/mesh_skinned.pc.hlsl", lit = true, skinned = true)
	mbi.skinned_lit_pipeline = create_render_pipeline(#load("shaders/mesh_skinned_lit.pc.hlsl"), #load("shaders/mesh_skinned_lit.pc.refl", string), "shaders/mesh_skinned_lit.pc.hlsl", lit = true, skinned = true)

	// The engine's blocks are the size of its structs (check_engine_blocks made sure each shader agrees), made when
	// any shader reads them. The game's block is as big as mesh.mbs says, and starts out as zeros: set_shader_value
	// writes mesh.mbs's uniforms, so a game block in a lit shader would be one nothing fills
	uses :: proc(kind:Block_Kind) -> bool {
		return mbi.pipeline.reflection.blocks[kind].present || mbi.lit_pipeline.reflection.blocks[kind].present || mbi.vertex_lit_pipeline.reflection.blocks[kind].present || mbi.skinned_pipeline.reflection.blocks[kind].present || mbi.skinned_lit_pipeline.reflection.blocks[kind].present
	}
	ensure(mbi.lit_pipeline.reflection.blocks[.GAME].present == false, "mesh_lit.mbs declares game uniforms, which set_shader_value can't reach")
	ensure(mbi.vertex_lit_pipeline.reflection.blocks[.GAME].present == false, "mesh_vertex_lit.mbs declares game uniforms, which set_shader_value can't reach")
	if uses(.FRAME) do mbi.frame_constants = create_constant_buffer(size_of(Frame_Constants))
	if uses(.RENDER) do mbi.render_constants = create_constant_buffer(size_of(Render_Constants))
	if uses(.LIGHTS) do mbi.lights_constants = create_constant_buffer(size_of(Lights_Block))
	if uses(.SKIN) do mbi.skin_constants = create_constant_buffer(u32(mbi.skin_settings.joint_limit * 3 * 16))
	if mbi.pipeline.reflection.blocks[.GAME].present {
		mbi.game_shadow = make([]byte, mbi.pipeline.reflection.blocks[.GAME].size)
		mbi.game_constants = create_constant_buffer(u32(len(mbi.game_shadow)))
		mbi.game_dirty = true
	}

	create_states()
}

/*
	Compiles one shader and makes its input layout. `lit` says it draws Lit_Vertex meshes, so its layout may read
	the normal; the unlit shader is refused one, since it also draws plain Vertex meshes that have none
*/
@(private)
create_render_pipeline :: proc(source:[]u8, reflection_text:string, name:cstring, lit:bool, skinned := false) -> (pipeline:Render_Pipeline) {
	reflection_ok:bool
	reflection_message:string
	pipeline.reflection, reflection_ok, reflection_message = parse_reflection(reflection_text)
	ensure(reflection_ok, reflection_message)
	check_message := check_engine_blocks(&pipeline.reflection)
	ensure(check_message == "", check_message)

	compile_shader(source, name, "vertex_main", "vs_5_0", &pipeline.vertex_shader_blob)
	compile_shader(source, name, "fragment_main", "ps_5_0", &pipeline.pixel_shader_blob)

	result := mbi.device->CreateVertexShader(
		pShaderBytecode = pipeline.vertex_shader_blob->GetBufferPointer(),
		BytecodeLength = pipeline.vertex_shader_blob->GetBufferSize(),
		pClassLinkage = nil,
		ppVertexShader = &pipeline.vertex_shader,
	)

	ensure(win.SUCCEEDED(result), "Vertex shader creation failed")

	result = mbi.device->CreatePixelShader(
		pShaderBytecode = pipeline.pixel_shader_blob->GetBufferPointer(),
		BytecodeLength = pipeline.pixel_shader_blob->GetBufferSize(),
		pClassLinkage = nil,
		ppPixelShader = &pipeline.pixel_shader,
	)
	ensure(win.SUCCEEDED(result), "Pixel shader creation failed")

	// The input layout is what the shader reads, each attribute found in the engine's Vertex or Lit_Vertex
	input_element_descs := make([]d3d11.INPUT_ELEMENT_DESC, len(pipeline.reflection.attributes), context.temp_allocator)
	for attribute, index in pipeline.reflection.attributes {
		found, message := find_vertex_attribute(attribute, lit, skinned)
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
		pShaderBytecodeWithInputSignature = pipeline.vertex_shader_blob->GetBufferPointer(),
		BytecodeLength = pipeline.vertex_shader_blob->GetBufferSize(),
		ppInputLayout = &pipeline.input_layout,
	)

	ensure(win.SUCCEEDED(result), "Input layout creation failed")
	return
}

@(private)
destroy_render_pipeline :: proc(pipeline:^Render_Pipeline) {
	destroy_reflection(&pipeline.reflection)
	pipeline.input_layout->Release()
	pipeline.pixel_shader_blob->Release()
	pipeline.pixel_shader->Release()
	pipeline.vertex_shader_blob->Release()
	pipeline.vertex_shader->Release()
	pipeline^ = {}
}

/*Everything drawn until camera_end is seen through this camera*/
camera_start :: proc(camera:Camera) {
	ensure(mbi.camera_active == false, "camera_start called again before camera_end")

	check_camera_destination(camera)
	draw_size := get_draw_size()
	window :=[2]f32{f32(draw_size.x), f32(draw_size.y)}
	aspect := calculate_window_aspect()

	// With pixel_snap, draw through a copy moved onto the pixel grid. render_sprite reads
	// pixel_scale to snap sprite edges the same way
	used := calculate_camera_snapped(camera, window)
	mbi.pixel_scale = calculate_camera_snap_scale(camera, window.y)

	mbi.view = calculate_camera_view_matrix(used) // render_mesh needs it to sort transparent items
	mbi.camera_active = true
	mbi.screen_pass = camera.screen
	mbi.camera_fov_y = used.fov_y if used.projection == .PERSPECTIVE else 0 // billboards read these two (billboard.odin)
	mbi.camera_window_height = window.y
	// While the bottom screen fills the window, the world and HUD are not shown. bottom_screen_start
	// sets this again for its own pass (bottom_screen_one_surface.odin)
	mbi.discard_pass = is_top_screen_hidden()

	// linalg builds OpenGL depth (-1..1); GL_TO_D3D_DEPTH converts it to D3D's 0..1
	view_projection := GL_TO_D3D_DEPTH * calculate_camera_projection_gl(used, aspect) * mbi.view
	set_frame_constants(view_projection, mbi.view)
}

/*Sorts and draws everything queued since camera_start*/
camera_end :: proc() {
	ensure(mbi.camera_active == true, "camera_end called without camera_start")

	// A hidden pass was queued but is never drawn
	if mbi.discard_pass == true {
		mbi.skybox.has_pending = false
		clear(&mbi.opaque_items)
		clear(&mbi.transparent_items)
		clear(&mbi.skin_state.rows)
		mbi.camera_active = false
		mbi.screen_pass = false
		mbi.discard_pass = false
		return
	}
	note_screen_drawn()

	// A screen camera has no depth buffer to lean on, so what is drawn last lands on top
	depth_opaque := Depth_Mode.OPAQUE
	depth_transparent := Depth_Mode.TRANSPARENT
	if mbi.screen_pass == true {
		depth_opaque = .DISABLED
		depth_transparent = .DISABLED
	}

	sort_render_queue()
	set_lights_constants()
	draw_pending_skybox() // first, so everything else covers it

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
	clear(&mbi.skin_state.rows)
	mbi.camera_active = false
	mbi.screen_pass = false
}

@(private)
destroy_pipeline :: proc() {
	delete(mbi.opaque_items)
	delete(mbi.transparent_items)

	if mbi.skin_constants != nil do mbi.skin_constants->Release()
	if mbi.lights_constants != nil do mbi.lights_constants->Release()
	delete(mbi.skin_state.rows)
	if mbi.game_constants != nil do mbi.game_constants->Release()
	if mbi.render_constants != nil do mbi.render_constants->Release()
	if mbi.frame_constants != nil do mbi.frame_constants->Release()
	delete(mbi.game_shadow)

	destroy_states()
	destroy_skybox_state()

	destroy_render_pipeline(&mbi.skinned_lit_pipeline)
	destroy_render_pipeline(&mbi.skinned_pipeline)
	destroy_render_pipeline(&mbi.vertex_lit_pipeline)
	destroy_render_pipeline(&mbi.lit_pipeline)
	destroy_render_pipeline(&mbi.pipeline)
}
