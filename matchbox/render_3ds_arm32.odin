package matchbox

/*
	Render
	======
	Handles the rendering
*/

import win "core:sys/windows"
import "core:mem"

import "vendor:directx/d3d11"

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
	mbi.device_context-> OMSetRenderTargets(1, &mbi.framebuffer_view, nil)
	
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

/*Renders a triangle -- specifically adds vertex data to global array that will be rendered
a, b, c are the points that make up the triangle*/
render_triangle :: proc(a, b, c:[2]f32, color:[4]f32) {

	if len(batch.verticies) + 3 > MAX_BATCH_VERTICIES {
		flush() // No more space in the buffer to just draw what we have and start again
	}

	append(&batch.verticies, Vertex{a, color}, {b, color}, {c, color})
	
	
	// mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	// mbi.device_context->IASetInputLayout(mbi.input_layout)

	// mbi.device_context->VSSetShader(mbi.vertex_shader, nil, 0)
	// mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)

	// mbi.device_context->IASetVertexBuffers(0, 1, &mbi.vertex_buffer, &mbi.vertex_stride, &mbi.vertex_offset)

	// mbi.device_context->Draw(mbi.vertex_count, 0)
}

render_sprite :: proc(sprite:Sprite) {
	// TODO: Implement
}

clear_background :: proc(color:[4]f32) {
	color := color
	mbi.device_context->ClearRenderTargetView(mbi.framebuffer_view, &color)
}
