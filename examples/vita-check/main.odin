package vita_check

/*
	The Vita hardware check: every feature Phase V brought up, one step at a time, each saying
	on screen what it should look like. Steps advance every 6 s; L and R go back and forward,
	START or SELECT quits. Build with `vita_build.bat examples\vita-check`.

	A real Vita has no log window, so each step is written to ux0:data/matchbox.log as it
	starts and again once its first frame is drawn. After a hang or a crash, the log's last
	line names the step: "started" with no "drew a frame" means it never finished a frame. A
	crash's own message lands in the same file.

	The lighting steps (G2 L7) draw model-check's scene lit per pixel, lit per vertex and with lighting off.

	Vita only: the memory step reads the kernel's free memory through vito.
*/

import "core:fmt"
import "core:math"
import "core:math/linalg"
import mb "../../matchbox"
import "../../matchbox/vito/sce"

STEP_SECONDS :: 6
LEAK_CYCLES :: 1000

Step :: enum {
	CLEAR,
	SHAPES,
	DEPTH,
	CULLING,
	TEXTURES,
	ANIMATION,
	SCENE_3D,
	LIGHT_PER_PIXEL,
	LIGHT_PER_VERTEX,
	LIGHT_OFF,
	TEXT,
	TOUCH,
	MEMORY,
	DONE,
}

// What each step should look like, shown under its name
step_descriptions := [Step]string {
	.CLEAR = "Only a plain blue screen.",
	.SHAPES = "White box left, red circle right with a see-through white square on it, yellow triangle on top, green line under.",
	.DEPTH = "Two red boxes, each with a white box ON TOP of it. Left: white sent first; right: white sent last.",
	.CULLING = "Two yellow triangles, left and right. Nothing in the middle: that one faces away and is culled.",
	.TEXTURES = "Orange/white checker: blocky on the left, smooth on the right. In the middle the top-left frame of the cat sheet (a PNG from the .vpk).",
	.ANIMATION = "The swordswoman playing through her frames.",
	.SCENE_3D = "A spinning orange/white checker cube, a see-through green pane sliding through it. The cube hides the pane where in front.",
	.LIGHT_PER_PIXEL = "Lit per pixel: blue cube, front and right sides alike, top lighter. Green sphere, small sharp white highlight. Pale grey checker board behind, holes see through.",
	.LIGHT_PER_VERTEX = "Lit per vertex: the same scene. Cube, floor and board look as before; only the sphere changes, its highlight softer and dimmer.",
	.LIGHT_OFF = "Lighting off: no shading. The cube is one bright blue on every side, the sphere one flat green with no highlight, the board and floor plain.",
	.TEXT = "Three sizes of clean text. Letters with tails (g j p q y) should not be cut off.",
	.TOUCH = "Touch the front screen: a green square follows your finger, and the numbers show where.",
	.MEMORY = "Creates and destroys a cube and a texture 1000 times. Free memory after should equal before.",
	.DONE = "All steps done. L / R to look at a step again, START to quit.",
}

Memory :: struct {
	user, cdram:i32,
}

read_free_memory :: proc() -> Memory {
	info := sce.KernelFreeMemorySizeInfo{size = size_of(sce.KernelFreeMemorySizeInfo)}
	sce.sceKernelGetFreeMemorySize(&info)
	return {info.size_user, info.size_cdram}
}

make_cube :: proc(colored:bool) -> mb.Mesh {
	vertices, indices := mb.mesh_cube(colored = colored)
	defer delete(vertices)
	defer delete(indices)
	return mb.create_lit_mesh(vertices, indices)
}

main :: proc() {
	mb.init("vita check", 960, 544)
	mb.print("vita check lit (G2 L7): started")

	// The 2D camera's units are screen pixels: the window is 544 tall, 0, 0 the centre, +y up
	camera_2d := mb.create_camera_2d()
	camera_3d := mb.Camera {
		position = {0, 2, 5},
		target = {0, 0, 0},
		up = {0, 1, 0},
		fov_y = 60,
		near = 0.1,
		far = 100,
		zoom = 1,
		projection = .PERSPECTIVE,
	}
	label_camera := mb.create_screen_camera(544)
	label_font := mb.create_font(mb.DEFAULT_FONT_BYTES, 24, pixels_per_unit = 1)
	text_fonts := [3]mb.Font {
		mb.create_font(mb.DEFAULT_FONT_BYTES, 16, pixels_per_unit = 1),
		mb.create_font(mb.DEFAULT_FONT_BYTES, 32, pixels_per_unit = 1),
		mb.create_font(mb.DEFAULT_FONT_BYTES, 64, pixels_per_unit = 1),
	}

	checker_pixels:[8 * 8 * 4]u8
	for y in 0 ..< 8 do for x in 0 ..< 8 {
		i := (y * 8 + x) * 4
		orange := (x + y) % 2 == 0
		checker_pixels[i + 0] = 255
		checker_pixels[i + 1] = 140 if orange else 255
		checker_pixels[i + 2] = 0 if orange else 255
		checker_pixels[i + 3] = 255
	}
	checker_point := mb.create_texture_from_pixels(&checker_pixels, 8, 8, .POINT)
	checker_linear := mb.create_texture_from_pixels(&checker_pixels, 8, 8, .LINEAR)
	cat := mb.create_sprite(mb.load_texture("meme_cat.png"))
	cat.scale = {80, 80}
	shia_clip := mb.create_animation_clip(mb.load_texture("shia.png", .POINT), 0.08)
	// She fills only the lower middle of each 128 pixel frame, so the frame is drawn large and
	// raised to bring her feet near the bottom of the screen
	shia := mb.create_animated_sprite_from_clip(shia_clip, scale = 800)
	shia.position.y = 170

	triangle_yellow := [4]f32{1, 1, 0, 1}
	counter_clockwise := mb.create_mesh(
		{{position = {-60, -50, 0}, color = triangle_yellow}, {position = {60, -50, 0}, color = triangle_yellow}, {position = {0, 60, 0}, color = triangle_yellow}},
		{0, 1, 2},
	)
	clockwise := mb.create_mesh(
		{{position = {-60, -50, 0}, color = triangle_yellow}, {position = {0, 60, 0}, color = triangle_yellow}, {position = {60, -50, 0}, color = triangle_yellow}},
		{0, 1, 2},
	)
	textured_cube := make_cube(colored = false)
	quad_vertices, quad_indices := mb.mesh_quad()
	pane := mb.create_mesh(quad_vertices, quad_indices)
	delete(quad_vertices)
	delete(quad_indices)

	// The lighting steps (G2 L7): model-check's scene, one sun from (1, 2, 1) and 0.2 ambient
	light_camera := mb.Camera {
		position = {0, 2.5, 6},
		target = {0, 0.5, 0},
		up = {0, 1, 0},
		fov_y = 50,
		near = 0.1,
		far = 100,
		zoom = 1,
		projection = .PERSPECTIVE,
	}
	light_floor := mb.create_plane_model(12)
	light_cube := mb.create_cube_model()
	light_sphere := mb.create_sphere_model(0.5)
	light_holes:[8 * 8][4]u8
	for &pixel, index in light_holes {
		pixel = {255, 255, 255, 255} if (index % 8 + index / 8) % 2 == 0 else {0, 0, 0, 0}
	}
	light_board_texture := mb.create_texture_from_pixels(&light_holes, 8, 8, .POINT)
	light_board := mb.create_plane_model(1.5)
	light_board.parts[0].texture = light_board_texture
	light_board.parts[0].alpha_cutoff = 0.5
	light_board.parts[0].cull = .NONE
	// The plane faces up; a quarter turn about X stands it up facing the camera
	light_board_transform := mb.create_transform({0, 0.5, -1.5}, mb.calculate_rotation_axis_angle({1, 0, 0}, math.PI / 2))
	mb.set_lights({mb.create_directional_light({-1, -2, -1})})

	leak_pixels := make([]u8, 64 * 64 * 4)
	defer delete(leak_pixels)
	memory_before, memory_after:Memory
	leak_cycles_done := 0

	step := Step.CLEAR
	step_time:f32 = 0
	step_drew := false
	time:f32 = 0
	mb.print("vita check: STEP", int(step) + 1, step, "started")

	for mb.is_running() {
		mb.poll_events()
		delta_time := mb.get_delta_time()
		time += delta_time
		step_time += delta_time
		if mb.is_gamepad_pressed(.START) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()

		next := step
		if mb.is_gamepad_pressed(.RIGHT_SHOULDER) && step < .DONE do next = Step(int(step) + 1)
		if mb.is_gamepad_pressed(.LEFT_SHOULDER) && step > .CLEAR do next = Step(int(step) - 1)
		if step != .DONE && step_time >= STEP_SECONDS && (step != .MEMORY || leak_cycles_done >= LEAK_CYCLES) do next = Step(int(step) + 1)
		if next != step {
			step = next
			step_time = 0
			step_drew = false
			mb.print("vita check: STEP", int(step) + 1, step, "started")
			if step == .MEMORY {
				leak_cycles_done = 0
				memory_before = read_free_memory()
			}
		}

		mb.update_animation(&shia, delta_time)

		// Ten create/destroy cycles a frame, so 1000 take under 2 s
		if step == .MEMORY && leak_cycles_done < LEAK_CYCLES {
			for _ in 0 ..< 10 {
				cube := make_cube(colored = true)
				texture := mb.create_texture_from_pixels(raw_data(leak_pixels), 64, 64)
				mb.destroy(cube)
				mb.destroy_texture(texture)
			}
			leak_cycles_done += 10
			if leak_cycles_done >= LEAK_CYCLES {
				memory_after = read_free_memory()
				mb.print("vita check: memory before", memory_before, "after", memory_after)
			}
		}

		mb.render_start()
		mb.clear_background(mb.CORNFLOWER_BLUE)

		#partial switch step {
		case .SHAPES:
			mb.camera_start(camera_2d)
			mb.render_rectangle({-250, 0, 0}, {150, 100}, mb.WHITE)
			mb.render_circle({220, 0, 0}, 70, {1, 0, 0, 1})
			mb.render_rectangle({220, 0, 1}, {80, 80}, {1, 1, 1, 0.5})
			mb.render_triangle({-60, 80, 0}, {60, 80, 0}, {0, 170, 0}, {1, 1, 0, 1})
			mb.render_line({-300, -120, 0}, {300, -120, 0}, 8, {0, 0.8, 0, 1})
			mb.camera_end()

		case .DEPTH:
			mb.camera_start(camera_2d)
			mb.render_rectangle({-240, 0, 1}, {120, 80}, mb.WHITE)
			mb.render_rectangle({-240, 0, 0}, {240, 160}, {1, 0, 0, 1})
			mb.render_rectangle({240, 0, 0}, {240, 160}, {1, 0, 0, 1})
			mb.render_rectangle({240, 0, 1}, {120, 80}, mb.WHITE)
			mb.camera_end()

		case .CULLING:
			mb.camera_start(camera_2d)
			mb.render_mesh(counter_clockwise, linalg.matrix4_translate_f32({-250, 0, 0}))
			mb.render_mesh(clockwise, linalg.matrix4_translate_f32({0, 0, 0}))
			mb.render_mesh(clockwise, linalg.matrix4_translate_f32({250, 0, 0}), cull = .NONE)
			mb.camera_end()

		case .TEXTURES:
			mb.camera_start(camera_2d)
			left := mb.create_sprite(checker_point)
			left.scale = {25, 25}
			left.position = {-300, 0, 0}
			right := mb.create_sprite(checker_linear)
			right.scale = {25, 25}
			right.position = {300, 0, 0}
			mb.render_sprite(left)
			mb.render_sprite(right)
			mb.render_sprite(cat)
			mb.camera_end()

		case .ANIMATION:
			mb.camera_start(camera_2d)
			mb.render_animated_sprite(shia)
			mb.camera_end()

		case .SCENE_3D:
			mb.camera_start(camera_3d)
			spin := mb.calculate_rotation_euler(yaw = time, pitch = time * 0.6)
			mb.render_mesh(textured_cube, mb.calculate_model_matrix({0, 0, 0}, spin, {1.5, 1.5, 1.5}), texture = checker_point)
			slide := 2.5 * math.sin(time * 1.3)
			mb.render_mesh(pane, mb.calculate_model_matrix({0, 0, slide}, scale = {3, 3, 1}), tint = {0.2, 1, 0.4, 0.5}, blend = .ALPHA, cull = .NONE)
			mb.camera_end()

		case .LIGHT_PER_PIXEL, .LIGHT_PER_VERTEX, .LIGHT_OFF:
			mode := mb.Lighting_Mode.PER_VERTEX if step == .LIGHT_PER_VERTEX else .PER_PIXEL
			mb.set_lighting({enabled = step != .LIGHT_OFF, ambient = {0.2, 0.2, 0.2, 1}, mode = mode})
			mb.camera_start(light_camera)
			mb.render_model(light_floor, [3]f32{0, -0.5, 0}, tint = {0.4, 0.4, 0.45, 1})
			mb.render_model(light_board, light_board_transform)
			mb.render_model(light_cube, [3]f32{-1.6, 0, 0}, tint = {0.4, 0.6, 1, 1})
			mb.render_model(light_sphere, [3]f32{1.6, 0, 0}, tint = {0.4, 1, 0.5, 1})
			mb.camera_end()

		case .TEXT:
			mb.camera_start(camera_2d)
			mb.render_text(text_fonts[2], "Matchbox gjpqy!", {-440, 120, 0})
			mb.render_text(text_fonts[1], "The quick brown fox jumps over 0123456789", {-440, 40, 0})
			mb.render_text(text_fonts[0], "Small: ~!@#$%^&*()_+-={}[]|:;<>,.?/", {-440, -10, 0})
			mb.render_text_wrapped(text_fonts[1], "Wrapped text across a narrow column, to check the line height and that words break at spaces.", {-440, -40, 0}, 420)
			mb.camera_end()

		case .TOUCH:
			mb.camera_start(camera_2d)
			touch := mb.calculate_mouse_world_position(camera_2d)
			if mb.is_mouse_held(.LEFT) do mb.render_rectangle({touch.x, touch.y, 0}, {60, 60}, {0, 1, 0, 1})
			screen := mb.get_mouse_position()
			state := "held" if mb.is_mouse_held(.LEFT) else "not held"
			mb.render_text(text_fonts[1], fmt.tprintf("screen %v, %v   world %.0f, %.0f   %s", screen.x, screen.y, touch.x, touch.y, state), {-440, -200, 0})
			mb.camera_end()

		case .MEMORY:
			mb.camera_start(camera_2d)
			mb.render_text(text_fonts[1], fmt.tprintf("cycles %v / %v", leak_cycles_done, LEAK_CYCLES), {-440, 60, 0})
			mb.render_text(text_fonts[1], fmt.tprintf("free before: user %v  cdram %v", memory_before.user, memory_before.cdram), {-440, 10, 0})
			if leak_cycles_done >= LEAK_CYCLES {
				mb.render_text(text_fonts[1], fmt.tprintf("free after:  user %v  cdram %v", memory_after.user, memory_after.cdram), {-440, -40, 0})
				if memory_before == memory_after {
					mb.render_text(text_fonts[1], "SAME: no leak", {-440, -100, 0}, {0, 1, 0, 1})
				} else {
					mb.render_text(text_fonts[1], "DIFFERENT: GPU memory leaked", {-440, -100, 0}, {1, 0.2, 0.2, 1})
				}
			}
			mb.camera_end()
		}

		// The step's name and what it should look like, over everything
		mb.camera_start(label_camera)
		mb.render_rectangle({0, 217, 0}, {960, 110}, {0, 0, 0, 0.6}) // tall enough for the title and two lines
		mb.render_text(label_font, fmt.tprintf("Step %v / %v: %v", int(step) + 1, len(Step), step), {-470, 245, 0}, {1, 1, 0, 1})
		mb.render_text_wrapped(label_font, step_descriptions[step], {-470, 225, 0}, 940)
		mb.camera_end()

		mb.render_end()

		if step_drew == false {
			step_drew = true
			mb.print("vita check: STEP", int(step) + 1, step, "drew a frame")
		}
	}

	mb.print("vita check: quit normally")
	for font in text_fonts do mb.destroy_font(font)
	mb.destroy_font(label_font)
	mb.destroy_texture(checker_point)
	mb.destroy_texture(checker_linear)
	mb.destroy(cat)
	mb.destroy(counter_clockwise)
	mb.destroy(clockwise)
	mb.destroy(textured_cube)
	mb.destroy(pane)
	mb.destroy(light_floor)
	mb.destroy(light_cube)
	mb.destroy(light_sphere)
	mb.destroy(light_board)
	mb.destroy(light_board_texture)
	mb.cleanup()
}
