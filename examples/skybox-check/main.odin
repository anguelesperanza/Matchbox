#+build windows

package skybox_check

/*
	The sky, on PC only (the handhelds' render_skybox stops with a message). Run from the repository root with
	`odin run examples/skybox-check`.

	Both skies are made in code, so there is no file to find: a cube map whose six faces are different colours with a
	white stripe down the middle of each, and an equirectangular panorama that is a sunset gradient with a vertical
	stripe every 45 degrees. Load a real one with `mb.load_skybox_cubemap("sky.png")` (a horizontal cross in
	assets/images) or `mb.load_skybox_panorama(...)`.

	Controls: left and right turn, up and down look; C the cube map, P the panorama, T tints the sky orange and back;
	Escape quits.

	What should show: a grey cube on the floor of the view, and behind it the sky. Turning right from the start (looking
	down -Z) goes through the cube map's faces in the order -Z (cyan), the one labelled -X (green), +Z (magenta) and the
	one labelled +X (red): continuous, never mirrored. The up and down arrows reach +Y (blue) and -Y (yellow)
*/

import "core:math"
import mb "../../matchbox"

FACE_SIZE :: 64

main :: proc() {
	mb.init("skybox check", 960, 544)

	cube_sky := make_cube_sky()
	panorama_sky := make_panorama_sky()
	cube := mb.create_cube_model(1)
	font := mb.create_font(mb.DEFAULT_FONT_BYTES, 32)

	use_cube := true
	tinted := false
	yaw:f32 = 0
	pitch:f32 = 0

	for mb.is_running() {
		if mb.is_key_pressed(.ESCAPE) do break
		if mb.is_key_pressed(.C) do use_cube = true
		if mb.is_key_pressed(.P) do use_cube = false
		if mb.is_key_pressed(.T) do tinted = !tinted

		delta := mb.get_delta_time()
		// Yaw 0 looks down -Z and a positive yaw turns left (camera_3d.odin), so right is negative
		if mb.is_key_held(.LEFT) do yaw += delta
		if mb.is_key_held(.RIGHT) do yaw -= delta
		if mb.is_key_held(.UP) do pitch += delta
		if mb.is_key_held(.DOWN) do pitch -= delta
		pitch = clamp(pitch, -math.PI * 0.49, math.PI * 0.49)

		tint := [4]f32{1, 0.7, 0.4, 1} if tinted else {1, 1, 1, 1}
		cube_sky.tint = tint
		panorama_sky.tint = tint

		direction := mb.calculate_direction_from_angles(yaw, pitch)
		camera := mb.create_camera_3d({0, 0, 0}, direction, 70)

		mb.render_start()
		mb.clear_background({0, 0, 0, 1})

		mb.camera_start(camera)
		// Recorded first or last, the sky is drawn before everything else in the camera
		mb.render_model(cube, [3]f32{0, -1, -4}, tint = {0.5, 0.5, 0.55, 1})
		mb.render_skybox(cube_sky if use_cube else panorama_sky)
		mb.camera_end()

		mb.render_end()
	}

	mb.destroy(cube_sky)
	mb.destroy(panorama_sky)
	mb.destroy(cube)
	mb.destroy_font(font)
}

// Six flat faces in a cube map's order (+X, -X, +Y, -Y, +Z, -Z), each with a white stripe down the middle
make_cube_sky :: proc() -> mb.Skybox {
	colors := [6][4]u8 {
		{255, 0, 0, 255},
		{0, 255, 0, 255},
		{0, 0, 255, 255},
		{255, 255, 0, 255},
		{255, 0, 255, 255},
		{0, 255, 255, 255},
	}

	faces:[6][FACE_SIZE * FACE_SIZE][4]u8
	pointers:[6]rawptr
	for &face, index in faces {
		for &pixel, position in face {
			x := position % FACE_SIZE
			pixel = {255, 255, 255, 255} if abs(x - FACE_SIZE / 2) < 2 else colors[index]
		}
		pointers[index] = &face
	}
	return mb.create_skybox_cubemap(pointers, FACE_SIZE)
}

// A sunset: dark blue overhead, orange at the horizon, dark ground below, and a stripe every 45 degrees
make_panorama_sky :: proc() -> mb.Skybox {
	WIDTH :: 512
	HEIGHT :: 256

	pixels := make([][4]u8, WIDTH * HEIGHT)
	defer delete(pixels)
	for y in 0 ..< HEIGHT {
		// 0 at the zenith, 1 at the nadir; the horizon is 0.5
		latitude := f32(y) / f32(HEIGHT - 1)
		color:[3]f32
		if latitude < 0.5 {
			color = {0.05, 0.1, 0.4} + ({1.0, 0.5, 0.2} - {0.05, 0.1, 0.4}) * (latitude * 2)
		} else {
			color = {0.15, 0.1, 0.1}
		}
		for x in 0 ..< WIDTH {
			pixel := [4]u8{u8(color.r * 255), u8(color.g * 255), u8(color.b * 255), 255}
			if x % (WIDTH / 8) < 2 do pixel = {255, 255, 255, 255}
			pixels[y * WIDTH + x] = pixel
		}
	}
	return mb.create_skybox_panorama(raw_data(pixels), WIDTH, HEIGHT)
}
