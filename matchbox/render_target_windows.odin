#+build windows

package matchbox

/*
	Render targets (PC)
	===================
	A render target is a D3D11 texture with a render target view to draw into and a shader resource view
	to read afterwards (the SRV is `texture.view`, so every draw that takes a Texture takes it).

	**The colour is `R8G8B8A8_UNORM_SRGB`, not the plain format the loaded images use**, to match the
	swapchain, which is `B8G8R8A8_UNORM_SRGB`. A draw writes linear colour and the hardware encodes it on
	the way in; sampling the sRGB view decodes it again, so a picture that goes through a target and
	then to the swapchain comes out exactly as if it had been drawn there. With a plain UNORM target the
	picture would be encoded once on the way in, never decoded, and encoded again at the screen: lighter.
*/

import win "core:sys/windows"

import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

/*
	The most samples the GPU does for `format` that do not exceed `wanted`: 8, 4, 2, then 1. Asked rather than assumed, because
	a software device or an old card may stop at 4, and creating a texture past what it does fails outright
*/
@(private)
get_supported_sample_count :: proc(format:dxgi.FORMAT, wanted:i32) -> i32 {
	count := max(wanted, 1)
	for count > 1 {
		levels:u32
		if win.SUCCEEDED(mbi.device->CheckMultisampleQualityLevels(format, u32(count), &levels)) && levels > 0 do return count
		count /= 2
	}
	return 1
}

@(private)
allocate_render_target :: proc(target:^Render_Target, filter:Filter_Mode) {
	target.samples = get_supported_sample_count(.R8G8B8A8_UNORM_SRGB, target.samples)
	multisampled := target.samples > 1

	description := d3d11.TEXTURE2D_DESC {
		Width = u32(target.width),
		Height = u32(target.height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM_SRGB,
		SampleDesc = {Count = 1},
		Usage = .DEFAULT,
		BindFlags = {.RENDER_TARGET, .SHADER_RESOURCE},
	}
	result := mbi.device->CreateTexture2D(&description, nil, &target.texture.texture)
	ensure(win.SUCCEEDED(result), "Create render target texture failed")
	result = mbi.device->CreateShaderResourceView(target.texture.texture, nil, &target.texture.view)
	ensure(win.SUCCEEDED(result), "Create render target shader view failed")

	// A multisampled texture cannot be sampled, so it is drawn into and then resolved into the one above (unbind_render_target)
	drawn_into := target.texture.texture
	if multisampled {
		description.SampleDesc = {Count = u32(target.samples)}
		description.BindFlags = {.RENDER_TARGET}
		result = mbi.device->CreateTexture2D(&description, nil, &target.msaa_texture)
		ensure(win.SUCCEEDED(result), "Create multisampled render target texture failed")
		drawn_into = target.msaa_texture
	}
	result = mbi.device->CreateRenderTargetView(drawn_into, nil, &target.color_view)
	ensure(win.SUCCEEDED(result), "Create render target view failed")

	if target.has_depth == false do return

	depth_description := d3d11.TEXTURE2D_DESC {
		Width = u32(target.width),
		Height = u32(target.height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .D32_FLOAT,
		SampleDesc = {Count = u32(target.samples)}, // the depth must have as many samples as the colour
		Usage = .DEFAULT,
		BindFlags = {.DEPTH_STENCIL},
	}
	result = mbi.device->CreateTexture2D(&depth_description, nil, &target.depth_texture)
	ensure(win.SUCCEEDED(result), "Create render target depth texture failed")
	result = mbi.device->CreateDepthStencilView(target.depth_texture, nil, &target.depth_view)
	ensure(win.SUCCEEDED(result), "Create render target depth view failed")
}

@(private)
free_render_target :: proc(target:^Render_Target) {
	if target.depth_view != nil do target.depth_view->Release()
	if target.depth_texture != nil do target.depth_texture->Release()
	if target.color_view != nil do target.color_view->Release()
	if target.msaa_texture != nil do target.msaa_texture->Release()
	destroy_texture(target.texture)
}

/*Points the GPU at the target, sizes the viewport to it and clears it unless `clear_color` is nil*/
@(private)
bind_render_target :: proc(target:^Render_Target, clear_color:Maybe([4]f32)) {
	mbi.drawing_multisampled = target.samples > 1
	color_view := target.color_view
	mbi.device_context->OMSetRenderTargets(1, &color_view, target.depth_view)

	viewport := d3d11.VIEWPORT{Width = f32(target.width), Height = f32(target.height), MaxDepth = 1}
	mbi.device_context->RSSetViewports(1, &viewport)
	// Scissor is always on (clip.odin) and an unset one is empty, which would draw nothing: start with the whole target
	set_scissor({}, false, {i32(target.width), i32(target.height)})

	if color, ok := clear_color.?; ok {
		color := color
		mbi.device_context->ClearRenderTargetView(target.color_view, &color)
		if target.depth_view != nil do mbi.device_context->ClearDepthStencilView(target.depth_view, {.DEPTH}, 1.0, 0)
	}
	set_render_state(.OPAQUE, .NONE, .BACK)
}

/*Back to the swapchain. The target's view is unbound first, so its texture can be sampled*/
@(private)
unbind_render_target :: proc(target:^Render_Target) {
	mbi.device_context->OMSetRenderTargets(0, nil, nil)
	if target.msaa_texture != nil {
		// sRGB formats resolve in linear light, so the average of an edge is the right grey rather than a dark one
		mbi.device_context->ResolveSubresource(target.texture.texture, 0, target.msaa_texture, 0, .R8G8B8A8_UNORM_SRGB)
	}
	bind_screen()
}

/*Binds the swapchain's colour and depth and the window's viewport: what render_start does at the top of the frame*/
@(private)
bind_screen :: proc() {
	viewport := d3d11.VIEWPORT {
		Width = f32(mbi.window_size[0]),
		Height = f32(mbi.window_size[1]),
		MaxDepth = 1,
	}
	mbi.device_context->RSSetViewports(1, &viewport)
	set_scissor({}, false, {mbi.window_size[0], mbi.window_size[1]})
	mbi.drawing_multisampled = mbi.window_samples > 1
	mbi.device_context->OMSetRenderTargets(1, &mbi.framebuffer_view, mbi.depth_view)
	set_render_state(.OPAQUE, .NONE, .BACK)
}

/*
	The target's picture as RGBA bytes, `width * 4` a row, top row first. Copied through a staging texture, so it waits
	for the GPU: not for every frame. The sRGB colour is as stored (what the screen would show), not decoded
*/
read_render_target_pixels :: proc(target:Render_Target, allocator := context.allocator) -> []u8 {
	pixels, _ := read_texture_pixels(target.texture.texture, allocator)
	return pixels
}

/*
	What the window is showing, as RGBA bytes, `width * 4` a row, top row first, with the size in pixels. For a
	screenshot, and for checking a change to the picture from a script. Call it after the last draw of the frame and
	before render_end: the swapchain throws the picture away when it presents, so afterwards it reads nothing sensible.
	It reads the window's own buffer: a game drawing into an internal resolution target gets that target's picture only
	once end_internal_frame has stretched it to the window, which render_end does, so read the target itself instead.
	Waits for the GPU, like read_render_target_pixels
*/
read_window_pixels :: proc(allocator := context.allocator) -> (pixels:[]u8, size:[2]i32) {
	return read_texture_pixels(mbi.framebuffer, allocator)
}

@(private)
read_texture_pixels :: proc(texture:^d3d11.ITexture2D, allocator := context.allocator) -> (pixels:[]u8, size:[2]i32) {
	description:d3d11.TEXTURE2D_DESC
	texture->GetDesc(&description)

	// A multisampled picture cannot be copied to the CPU: average its samples into a plain one of the same size first
	source_texture := texture
	if description.SampleDesc.Count > 1 {
		description.SampleDesc = {Count = 1}
		description.BindFlags = {}
		resolved:^d3d11.ITexture2D
		result := mbi.device->CreateTexture2D(&description, nil, &resolved)
		ensure(win.SUCCEEDED(result), "Create resolve texture failed")
		mbi.device_context->ResolveSubresource(resolved, 0, texture, 0, description.Format)
		source_texture = resolved
	}
	defer if source_texture != texture do source_texture->Release()

	description.Usage = .STAGING
	description.BindFlags = {}
	description.CPUAccessFlags = {.READ}
	description.MiscFlags = {}

	staging:^d3d11.ITexture2D
	result := mbi.device->CreateTexture2D(&description, nil, &staging)
	ensure(win.SUCCEEDED(result), "Create staging texture failed")
	defer staging->Release()
	mbi.device_context->CopyResource(staging, source_texture)

	mapped:d3d11.MAPPED_SUBRESOURCE
	result = mbi.device_context->Map(staging, 0, .READ, {}, &mapped)
	ensure(win.SUCCEEDED(result), "Map staging texture failed")
	defer mbi.device_context->Unmap(staging, 0)

	width, height := int(description.Width), int(description.Height)
	row_bytes := width * 4
	pixels = make([]u8, row_bytes * height, allocator)
	for row in 0 ..< height {
		source := ([^]u8)(mapped.pData)[row * int(mapped.RowPitch):]
		copy(pixels[row * row_bytes:][:row_bytes], source[:row_bytes])
	}

	// The swapchain's buffer is blue first; a screenshot is red first like every other picture here
	if description.Format == .B8G8R8A8_UNORM_SRGB || description.Format == .B8G8R8A8_UNORM {
		for index := 0; index < len(pixels); index += 4 {
			pixels[index], pixels[index + 2] = pixels[index + 2], pixels[index]
		}
	}
	return pixels, {i32(width), i32(height)}
}
