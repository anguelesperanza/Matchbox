#+build freestanding arm32

package matchbox

/*
	Render -- Vita
	==============
	Everything drawn is 3D; 2D is an orthographic camera. The GXM path is added in Phase V
	(see render_plan.md); until then a frame is begun, cleared and shown, and the queue is
	emptied without drawing.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "vito/gfx"

when VITA {

	render_start :: proc() {
		gfx.begin_frame()
	}

	/*Renders final output -- ends the scene and queues it for display, which waits for vsync*/
	render_end :: proc() {
		gfx.end_frame()
		gfx.swap()
	}

	/*
		Everything drawn until camera_end is seen through this camera. Records the same state
		the PC's does, so the shared queue (render.odin) fills exactly as it does there
	*/
	camera_start :: proc(camera:Camera) {
		ensure(mbi.camera_active == false, "camera_start called again before camera_end")

		window := [2]f32{f32(mbi.window_size[0]), f32(mbi.window_size[1])}
		used := calculate_camera_snapped(camera, window)
		mbi.pixel_scale = calculate_camera_snap_scale(camera, window.y)

		mbi.view = calculate_camera_view_matrix(used)
		mbi.camera_active = true
		mbi.screen_pass = camera.screen
	}

	/*
		Empties the queue without drawing it. Phase V draws it with GXM here; until then the
		queue is still cleared, or it would grow every frame
	*/
	camera_end :: proc() {
		ensure(mbi.camera_active == true, "camera_end called without camera_start")

		clear(&mbi.opaque_items)
		clear(&mbi.transparent_items)
		mbi.camera_active = false
		mbi.screen_pass = false
		mbi.discard_pass = false
	}

	/*Fills the screen with one colour, 0..1 RGBA. Call between render_start and render_end*/
	clear_background :: proc(color:[4]f32) {
		gfx.clear(color)
	}
}
