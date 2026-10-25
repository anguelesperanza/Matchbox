package matchbox

import win "core:sys/windows"
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

/*Renders final output -- Present all the gathered data this frame to the screen*/
render_end :: proc() {
	mbi.swapchain->Present(1, {})
}

/*Renders a triangle -- speficially gathers the commands to render a triangle*/
render_triangle :: proc() {
	mbi.device_context->IASetPrimitiveTopology(.TRIANGLELIST)
	mbi.device_context->IASetInputLayout(mbi.input_layout)

	mbi.device_context->VSSetShader(mbi.vertex_shader, nil, 0)
	mbi.device_context->PSSetShader(mbi.pixel_shader, nil, 0)

	mbi.device_context->IASetVertexBuffers(0, 1, &mbi.vertex_buffer, &mbi.vertex_stride, &mbi.vertex_offset)

	mbi.device_context->Draw(mbi.vertex_count, 0)
}

render_sprite :: proc(sprite:Sprite) {
	// TODO: Implement
}

clear_background :: proc(color:[4]f32) {
	color := color
	mbi.device_context->ClearRenderTargetView(mbi.framebuffer_view, &color)
}
