#+build windows

package matchbox

/*
	Render
	======
	Handles the rendering
*/

import win "core:sys/windows"
import "core:mem"

import "vendor:directx/d3d11"

// Constants
MAX_BATCH_VERTICIES :: 65536 // Total number of vertices that can be drawn at once

Vertex :: struct {
	position:[2]f32,
	color:[4]f32,
	uv:[2]f32,
}

Constants :: struct {
    viewport_size: [2]f32,
    _padding: [2]f32, // pads to 16 bytes
}

render_start :: proc() {
	if mbi.did_resize {
		mbi.device_context->OMSetRenderTargets(0, nil, nil)
		mbi.framebuffer_view->Release()
		mbi.framebuffer->Release()

		res := mbi.swapchain->ResizeBuffers(0, 0, 0, .UNKNOWN, {})
		ensure(win.SUCCEEDED(res), "Swapchain buffer resize failed")

		res = mbi.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&mbi.framebuffer))

	    res  = mbi.device->CreateRenderTargetView(mbi.framebuffer, nil, &mbi.framebuffer_view)
	    ensure(win.SUCCEEDED(res), "Create RenderTargetView failed")

		mbi.did_resize = false

	}

	window_rect:win.RECT
	win.GetClientRect(mbi.window, &window_rect)

	viewport := d3d11.VIEWPORT {
		TopLeftX = 0,
	    TopLeftY = 0,
	    Width    = f32(window_rect.right - window_rect.left),
	    Height   = f32(window_rect.bottom - window_rect.top),
	    MinDepth = 0,
	    MaxDepth = 1,
	}

	mbi.device_context->RSSetViewports(1, &viewport)
	mbi.device_context->VSSetConstantBuffers(0, 1, &mbi.constant_buffer)
	mbi.device_context-> OMSetRenderTargets(1, &mbi.framebuffer_view, nil)

	constants := Constants {
		viewport_size = {viewport.Width, viewport.Height}
	}

	mapped:d3d11.MAPPED_SUBRESOURCE
	res := mbi.device_context->Map(mbi.constant_buffer, 0, .WRITE_DISCARD, {}, &mapped)
	ensure(win.SUCCEEDED(res), "Map constant buffer failed")
	mem.copy(mapped.pData, &constants, size_of(Constants))
	mbi.device_context->Unmap(mbi.constant_buffer, 0)

}

flush :: proc() {
	count := u32(len(batch.verticies))
	if count == 0 do return // if we have nothing batches, don't do anything

	stride:u32 = size_of(Vertex)
	offset:u32 = 0

	mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	mbi.device_context->IASetInputLayout(mbi.input_layout)

	mbi.device_context->VSSetShader(mbi.vertex_shader, nil, 0)
	mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)

	mbi.device_context->PSSetShaderResources(0, 1, &batch.current_texture_view)
	mbi.device_context->PSSetSamplers(0, 1, &mbi.sampler)


	mbi.device_context->IASetVertexBuffers(0, 1, &batch.gpu_buffer, &stride, &offset)



	mapped:d3d11.MAPPED_SUBRESOURCE
	res := mbi.device_context->Map(batch.gpu_buffer, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, raw_data(batch.verticies), int(count) * size_of(Vertex))
	mbi.device_context->Unmap(batch.gpu_buffer, 0)

	mbi.device_context->Draw(count, 0)
	clear(&batch.verticies)
}

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	flush() // Draw everthing (in the vertex buffer)
	mbi.swapchain->Present(1, {})
}

/*Renders a triangle using points*/
render_triangle_points :: proc(a, b, c:[2]f32, color:[4]f32) {

	if len(batch.verticies) + 3 > MAX_BATCH_VERTICIES {
		flush() // No more space in the buffer to just draw what we have and start again
	}

	append(&batch.verticies, Vertex{a, color, {}}, {b, color, {}}, {c, color, {}})
}

/*Renders a triangle using triangle shape*/
render_triangle_shape :: proc(triangle:Triangle) {
	// render_triangle_points(
	// 	a = triangle.position + triangle.points[0],
	// 	b = triangle.position + triangle.points[1],
	// 	c = triangle.position + triangle.points[2],
	// 	color = triangle.color,
	// )
}

/*Renders a triangle*/
render_triangle :: proc {
	render_triangle_points,
	// render_triangle_shape,
}


/*Renders the sprite, with an optional tint (default is white -- no tint)*/
render_sprite :: proc(sprite:Sprite, tint:[4]f32 = {1, 1, 1, 1}) {

	if len(batch.verticies) + 6 > MAX_BATCH_VERTICIES {
		flush() // No more space in the buffer to just draw what we have and start again
	}

	if batch.current_texture_view != sprite.texture_view {
		flush() // "render" what we already have
		batch.current_texture_view = sprite.texture_view // update the view
	}

	top_left := Vertex{position = {sprite.x, sprite.y}, color = tint, uv = {0, 0}}
	top_right := Vertex{position = {sprite.x + cast(f32)sprite.width, sprite.y}, color = tint, uv = {1,0}}
	bottom_right := Vertex{position = {sprite.x + cast(f32)sprite.width, sprite.y + cast(f32)sprite.height}, color = tint, uv = {1,1}}
	bottom_left := Vertex{position = {sprite.x, sprite.y + cast(f32)sprite.height}, color = tint, uv = {0, 1}}

	append(&batch.verticies, top_left, top_right, bottom_right, top_left, bottom_right, bottom_left)
}

clear_background :: proc(color:[4]f32) {
	color := color
	mbi.device_context->ClearRenderTargetView(mbi.framebuffer_view, &color)
}
