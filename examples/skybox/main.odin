package skybox_example

/*
	The sky, from both of the shapes it ships as.

	A sky is not geometry. There is no dome and no very large cube: the pass
	draws one triangle over the whole screen and asks, per pixel, which way that
	pixel is looking -- then reads that direction out of an image. Which is why
	`draw_skybox` takes no transform and why moving the camera does not move the
	sky.

	The two formats differ only in how a direction becomes a colour:

	  - a **panorama** is one 2:1 equirectangular image, longitude across and
	    latitude down. An atan2 and an acos a pixel
	  - a **cube map** is six square faces packed as a cross. The hardware picks
	    the face and does the projection, so it is a compare and a divide

	Things to try:

	  - **press SPACE** to swap between them. Nothing else about the scene
	    changes, which is the point: the two are interchangeable at the call
	  - **look up, then straight down.** Both formats cover the whole sphere,
	    including the two poles, which is where a badly mapped sky pinches or
	    smears
	  - **turn all the way round.** The panorama's seam, where longitude comes
	    back to itself, is invisible because its sampler wraps in u. The cube
	    map's four vertical seams are invisible because the hardware filters
	    across them
	  - **walk toward the cubes.** The sky does not move, because it has no
	    position to move from. Walk far enough and the ground runs out, and the
	    sky carries on
	  - **press 1 and 2** to tint it. The tint multiplies the texture on the way
	    out, which is how a sky goes to dusk without a second image

	Set the two paths below to skies of your own. Both are as they came from a
	sky pack -- Matchbox does not repack them, and the cube cross is sliced by
	the labels the cross is drawn with.
*/

import "core:fmt"

import mb "../../matchbox"

PANORAMA :: "C:/Users/King-/OneDrive/Pictures/sbs_-_cloudy_skyboxes_-_panorama/Panorama/Panorama_Sky_01-512x512.png"
CUBEMAP  :: "C:/Users/King-/OneDrive/Pictures/sbs_-_cloudy_skyboxes_-_cubemap/Cubemap/Cubemap_Sky_02-512x512.png"

EYE_HEIGHT :: 1.7
WALK_SPEED :: 8.0

main :: proc() {
	mb.init("Skybox", 1280, 720)
	defer mb.cleanup()

	// Matchbox's diagnostics go to its logger, and Odin's default context
	// throws logging away. Without this line the loaders below fail silently.
	context.logger = mb.mbi.logger

	mb.set_escape_key(.UNKNOWN)

	panorama, panorama_ok := mb.load_skybox_panorama(PANORAMA)
	cubemap,  cubemap_ok  := mb.load_skybox_cubemap(CUBEMAP)

	if !panorama_ok && !cubemap_ok {
		fmt.eprintln("neither sky loaded -- set PANORAMA and CUBEMAP at the top of this file")
		return
	}

	defer mb.destroy(&panorama)
	defer mb.destroy(&cubemap)

	cube := mb.cube_model(1)
	defer mb.destroy(&cube)

	camera := mb.camera3d_at(position = {0, EYE_HEIGHT, 6}, target = {0, EYE_HEIGHT, 0})
	yaw, pitch := mb.camera3d_angles(camera)

	showing_cubemap := !panorama_ok
	tint            := mb.WHITE

	mb.set_cursor_locked(true)

	for mb.is_running() {
		mb.poll_events()
		dt := mb.delta_time()

		if mb.is_key_pressed(.ESCAPE) {
			if mb.cursor_locked() {
				mb.set_cursor_locked(false)
			} else {
				mb.mbi.running = false
			}
		}

		if !mb.cursor_locked() && mb.is_mouse_pressed(.LEFT) do mb.set_cursor_locked(true)

		if mb.is_key_pressed(.SPACE) && panorama_ok && cubemap_ok {
			showing_cubemap = !showing_cubemap
		}

		if mb.is_key_pressed(._1) do tint = mb.WHITE
		if mb.is_key_pressed(._2) do tint = {0.45, 0.35, 0.55, 1}

		if mb.cursor_locked() {
			mb.camera3d_first_person(&camera, &yaw, &pitch, WALK_SPEED, dt)
		}

		sky := cubemap if showing_cubemap else panorama
		sky.tint = tint

		mb.begin_drawing()
		mb.clear_background(mb.BLACK)

		mb.begin_drawing_3d(camera)

		// First, before anything else in the pass. It writes every pixel and
		// touches no depth, so what follows draws straight over it.
		mb.draw_skybox(sky)

		mb.draw_plane({0, 0, 0}, {30, 30}, {0.30, 0.34, 0.30, 1})
		mb.draw_grid(slices = 30, spacing = 1, color = {1, 1, 1, 0.15})

		for i in 0 ..< 6 {
			x := f32(i) * 2.5 - 6.5
			mb.draw_cube({x, 0.5 + f32(i) * 0.25, -6}, {1, 1 + f32(i) * 0.5, 1},
				{0.8, 0.75, 0.7, 1})
			mb.draw_cube_wires({x, 0.5 + f32(i) * 0.25, -6}, {1, 1 + f32(i) * 0.5, 1}, mb.BLACK)
		}

		mb.end_drawing_3d()

		font := &mb.mbi.font
		mb.draw_text(font, "WASD and mouse to look around", 20, 40, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("SPACE: showing the %v",
			"CUBEMAP (a 4x3 cross)" if showing_cubemap else "PANORAMA (2:1 equirectangular)"),
			20, 70, mb.WHITE)
		mb.draw_text(font, "1 and 2 tint it", 20, 100, mb.WHITE)
		mb.draw_text(font, fmt.tprintf("looking %.2f, %.2f", yaw, pitch), 20, 140, mb.WHITE)

		mb.end_drawing()
	}

	mb.wait_idle()
}
