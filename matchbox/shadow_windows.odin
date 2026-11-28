package matchbox

import "core:math/linalg"
import win "core:sys/windows"
import "vendor:directx/d3d11"

/*
	PC's shadow map: the depth of everything queued under set_shadow_casting(true), seen from the one light that casts (Light.casts_shadow).
	The lit shaders look it up per pixel at t7 / s7 (mbsc's mbs_light_shadow). A depth-only pass at the top of camera_end draws it, with the
	unlit mesh pipeline's vertex shader and no pixel shader, so the map needed no shader of its own.
*/
Shadow_Map :: struct {
	texture:^d3d11.ITexture2D, // R32_TYPELESS: written as depth, read as a float
	depth_view:^d3d11.IDepthStencilView,
	resource_view:^d3d11.IShaderResourceView,
	sampler:^d3d11.ISamplerState, // a comparison sampler: it answers "is this point nearer than the map", and bilinearly blends four such answers
	resolution:int,
	rendered:bool, // whether this camera's map is in place, so render_item binds it
}

// Where the lit shaders read the map and its sampler, as mbsc declares them.
SHADOW_MAP_REGISTER :: 7

@(private)
create_shadow_map :: proc(resolution:int) {
	map_description := d3d11.TEXTURE2D_DESC {
		Width = u32(resolution),
		Height = u32(resolution),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R32_TYPELESS,
		SampleDesc = {Count = 1},
		Usage = .DEFAULT,
		BindFlags = {.DEPTH_STENCIL, .SHADER_RESOURCE},
	}
	shadow := &mbi.shadow_map
	result := mbi.device->CreateTexture2D(&map_description, nil, &shadow.texture)
	ensure(win.SUCCEEDED(result), "Create shadow map texture failed")

	depth_description := d3d11.DEPTH_STENCIL_VIEW_DESC{Format = .D32_FLOAT, ViewDimension = .TEXTURE2D}
	result = mbi.device->CreateDepthStencilView(shadow.texture, &depth_description, &shadow.depth_view)
	ensure(win.SUCCEEDED(result), "Create shadow map depth view failed")

	resource_description := d3d11.SHADER_RESOURCE_VIEW_DESC{Format = .R32_FLOAT, ViewDimension = .TEXTURE2D}
	resource_description.Texture2D = {MipLevels = 1}
	result = mbi.device->CreateShaderResourceView(shadow.texture, &resource_description, &shadow.resource_view)
	ensure(win.SUCCEEDED(result), "Create shadow map resource view failed")

	if shadow.sampler == nil {
		sampler_description := d3d11.SAMPLER_DESC {
			Filter = .COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
			AddressU = .CLAMP,
			AddressV = .CLAMP,
			AddressW = .CLAMP,
			ComparisonFunc = .LESS_EQUAL,
			MaxLOD = d3d11.FLOAT32_MAX,
		}
		result = mbi.device->CreateSamplerState(&sampler_description, &shadow.sampler)
		ensure(win.SUCCEEDED(result), "Create shadow map sampler failed")
	}
	shadow.resolution = resolution
}

@(private)
free_shadow_map_texture :: proc() {
	shadow := &mbi.shadow_map
	if shadow.resource_view != nil do shadow.resource_view->Release()
	if shadow.depth_view != nil do shadow.depth_view->Release()
	if shadow.texture != nil do shadow.texture->Release()
	shadow.resource_view, shadow.depth_view, shadow.texture = nil, nil, nil
	shadow.resolution = 0
}

@(private)
destroy_shadow_map :: proc() {
	free_shadow_map_texture()
	if mbi.shadow_map.sampler != nil do mbi.shadow_map.sampler->Release()
	mbi.shadow_map.sampler = nil
}

/*
	Draws the shadow map for the camera about to be drawn, when a light casts. The map is cleared to the far plane even when nothing was queued
	to cast, so a lit shader reading it finds light everywhere rather than whatever was left in it. The target the camera draws to, its
	viewport, and the frame constants are put back afterwards: this runs in the middle of camera_end
*/
@(private)
render_shadow_map :: proc() {
	shadow := &mbi.shadow_map
	shadow.rendered = false
	if mbi.lighting.settings.enabled == false || mbi.screen_pass do return
	caster := calculate_shadow_caster(mbi.lighting)
	if caster < 0 do return

	settings := get_shadow_settings(mbi.lighting.settings.shadow)
	if shadow.texture == nil || shadow.resolution != settings.resolution {
		free_shadow_map_texture()
		create_shadow_map(settings.resolution)
	}

	// What to put back: the colour and depth the camera draws into and where in them it draws
	previous_color:^d3d11.IRenderTargetView
	previous_depth:^d3d11.IDepthStencilView
	mbi.device_context->OMGetRenderTargets(1, &previous_color, &previous_depth)
	view_count:u32 = 1
	previous_viewport:d3d11.VIEWPORT
	mbi.device_context->RSGetViewports(&view_count, &previous_viewport)
	was_multisampled := mbi.drawing_multisampled

	// The map is read in a shader at t7 while the previous camera's draw may still have it bound: unbind it before it is written
	no_view:^d3d11.IShaderResourceView
	mbi.device_context->PSSetShaderResources(SHADOW_MAP_REGISTER, 1, &no_view)
	mbi.device_context->VSSetShaderResources(SHADOW_MAP_REGISTER, 1, &no_view)

	mbi.device_context->OMSetRenderTargets(0, nil, shadow.depth_view)
	mbi.device_context->ClearDepthStencilView(shadow.depth_view, {.DEPTH}, 1.0, 0)
	viewport := d3d11.VIEWPORT{Width = f32(settings.resolution), Height = f32(settings.resolution), MaxDepth = 1}
	mbi.device_context->RSSetViewports(1, &viewport)
	set_scissor({}, false, {i32(settings.resolution), i32(settings.resolution)})
	mbi.drawing_multisampled = false

	light_matrix := calculate_shadow_matrix(mbi.lighting.lights[caster], mbi.lighting.settings.shadow)
	set_frame_constants(light_matrix, linalg.MATRIX4F32_IDENTITY)

	// Only the vertex shader runs: the depth is all this pass wants, and with no pixel shader the GPU writes it without shading anything
	pipeline := &mbi.pipeline
	mbi.device_context->PSSetShader(nil, nil, 0)
	mbi.device_context->VSSetShader(pipeline.vertex_shader, nil, 0)
	mbi.device_context->IASetInputLayout(pipeline.input_layout)
	for item in mbi.opaque_items {
		// A skinned mesh has its own vertex shader, a see-through one does not hide the light, and a screen item is not in the world
		if item.casts_shadow == false || item.mesh.skinned || item.mesh.lines do continue
		set_render_state(.OPAQUE, .NONE, item.cull)
		set_render_constants(item)
		vertex_buffer := item.mesh.vertex_buffer
		stride:u32 = size_of(Lit_Vertex) if item.mesh.lit else size_of(Vertex)
		offset:u32 = 0
		mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
		mbi.device_context->IASetVertexBuffers(0, 1, &vertex_buffer, &stride, &offset)
		mbi.device_context->IASetIndexBuffer(item.mesh.index_buffer, .R16_UINT, 0)
		buffers := [Block_Kind]^d3d11.IBuffer{.FRAME = mbi.frame_constants, .RENDER = mbi.render_constants, .GAME = mbi.game_constants, .LIGHTS = mbi.lights_constants, .SKIN = mbi.skin_constants}
		for block, kind in pipeline.reflection.blocks {
			if block.present == false do continue
			buffer := buffers[kind]
			mbi.device_context->VSSetConstantBuffers(u32(block.register), 1, &buffer)
		}
		mbi.device_context->DrawIndexed(item.mesh.index_count, 0, 0)
	}

	// Back to the camera's own target and constants
	mbi.device_context->OMSetRenderTargets(1, &previous_color, previous_depth)
	mbi.device_context->RSSetViewports(1, &previous_viewport)
	if previous_color != nil do previous_color->Release()
	if previous_depth != nil do previous_depth->Release()
	mbi.drawing_multisampled = was_multisampled
	set_frame_constants(mbi.camera_view_projection, mbi.view)
	set_render_state(.OPAQUE, .NONE, .BACK) // as bind_screen leaves it, which the skybox that is drawn next relies on
	shadow.rendered = true
}
