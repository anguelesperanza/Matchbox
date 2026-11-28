package shader_vita_check

/*
	Game shaders on the Vita (V4 and V5 of docs/game_shaders_vita_plan.md): loads shaders by name from the .vpk, draws a lit sphere
	and a sprite with each, and checks what the engine can answer: a missing shader is `ok` = false, a loaded one draws for
	FRAMES frames, destroying the current shader clears it. The loader prints what it found in each program (inputs kept, game
	uniforms found, textures, lights) to ux0:data/matchbox.log, which is the evidence for the parts of a draw nothing can read
	back: Vita3K cannot read GPU-written pixels, so a picture has to be looked at.

	The shaders come from the test projects' build_shaders.bat (games/shaders/<project>/assets/vita/shaders). Copy the three files
	per shader (`<name>_v.gxp`, `<name>_f.gxp`, `<name>.vita.refl`) into this folder's assets/vita\shaders, then
	`vita_build.bat examples\shader-vita-check`. The 11 distinct shaders of the 13 test files (haze's lava.mbs and the water
	project's water.mbs are byte-identical to lava and styalized-water's water) run in turn, each on a mesh it suits, with the
	built-in as the control. Then a stress pass draws the shaded object many times, back to front, so the fragment cost shows
	against the control. Each step's log line gives the average milliseconds a frame. START quits.

	Vita only: it reads nothing from the platform, but the shaders are .gxp files.
*/

import "core:fmt"
import mb "../../matchbox"
import "../../matchbox/vito/gfx"

FRAMES_PER_STEP :: 150
FIRST_TIMED_FRAME :: 20 // the first frames pay for pipeline creation and texture upload
STRESS_COPIES :: 12 // how many times the shaded object is drawn, back to front, in a stress step: overdraw makes the fragment cost show
WATER_CELLS :: 64

Scene :: enum {
	SPHERE, // a lit sphere, and a checker sprite beside it
	SHAPES, // a ground plane, a sphere, a tipped cylinder and a cube
	SEA, // a wave grid and a buoy cube
	SEA_ISLAND, // a wave grid and a squashed sphere standing in it
}

Step :: struct {
	shader:   string, // "" is the built-in, the control a shader's cost is read against
	lighting: bool,
	scene:    Scene,
	stress:   bool, // draw the shaded object STRESS_COPIES times, so the cost is a measurable part of the frame
	shade:    string, // which object the shader is on, for the scenes with two: "water" or "island"
	note:     string, // what the screen should show, so a look at it can say pass or fail
}

STEPS :: [?]Step {
	{"", true, .SPHERE, true, "", "CONTROL, the built-in, stressed: the lit orange checker sphere drawn many times. The cost every other stress step is read against."},
	{"shield", true, .SPHERE, false, "", "A blue-ish shield bubble on the sphere (hit rings at its front). The sprite on the right is the plain built-in checker: the shader reads the normal, so a sprite falls back."},
	{"hologram", true, .SPHERE, false, "", "A glitching hologram look on the sphere. The checker sprite is the built-in."},
	{"toon", true, .SPHERE, false, "", "Toon-banded lit sphere: hard bands of light and shadow. The checker sprite is the built-in."},
	{"toon", false, .SPHERE, false, "", "Lighting off: the toon shader reads the lights, so it falls back and the sphere is the built-in unlit tint (flat)."},
	{"lava", true, .SPHERE, false, "", "A flowing lava surface on the sphere. The checker sprite is the built-in."},
	{"haze", true, .SPHERE, false, "", "The sphere and the sprite both go through haze: the checker is bent by a wavy band across the middle."},
	{"crt", true, .SPHERE, false, "", "The sphere and the sprite both go through crt: scanlines and a mask over the checker, curved corners."},
	{"dissolve", true, .SHAPES, false, "", "Three shapes burn away and come back as progress runs 0 to 1: holes (discard) eat each shape with a glowing edge."},
	{"snow", true, .SHAPES, false, "", "White snow settles on the upward faces of the shapes; the ground is the built-in and bare."},
	{"water", true, .SEA, false, "", "A wave grid of blue water bobbing around a red buoy cube (built-in)."},
	{"dreamcast_water", true, .SEA_ISLAND, false, "water", "Stylised sea with see-through shallows around a tan island (built-in)."},
	{"sand", true, .SEA_ISLAND, false, "island", "The tan island gets sand shading, wet near the waterline; the sea is the built-in flat colour."},
	{"shield", true, .SPHERE, true, "", "STRESS: shield, the sphere drawn many times (compare the control)."},
	{"lava", true, .SPHERE, true, "", "STRESS: lava, the sphere drawn many times."},
	{"dissolve", true, .SHAPES, true, "", "STRESS: dissolve, the shapes drawn many times."},
	{"snow", true, .SHAPES, true, "", "STRESS: snow, the shapes drawn many times."},
	{"water", true, .SEA, true, "", "STRESS: water, the grid drawn many times."},
	{"dreamcast_water", true, .SEA_ISLAND, true, "water", "STRESS: dreamcast_water, the grid drawn many times."},
	{"toon", true, .SPHERE, true, "", "STRESS: toon."},
	{"", true, .SPHERE, true, "", "CONTROL again, the built-in, stressed."},
}

set_uniforms :: proc(shader: mb.Shader, name: string, time: f32, step_progress: f32) {
	switch name {
	case "shield":
		mb.set_shader_value("hit_a", [4]f32{0, 0.5, 1, time}, shader)
		mb.set_shader_value("hit_b", [4]f32{0.5, 0, 1, time * 0.5}, shader)
		mb.set_shader_value("hit_c", [4]f32{-0.5, -0.5, 1, time * 0.25}, shader)
	case "hologram":
		mb.set_shader_value("glitch", f32(1.0), shader)
	case "lava":
		mb.set_shader_value("heat", f32(1.0), shader)
	case "haze":
		mb.set_shader_value("strength", f32(0.02), shader)
		mb.set_shader_value("band_centre", f32(0.5), shader)
		mb.set_shader_value("band_width", f32(0.5), shader)
		mb.set_shader_value("aspect", f32(960.0 / 544.0), shader)
	case "crt":
		mb.set_shader_value("curvature", f32(0.10), shader)
		mb.set_shader_value("aberration", f32(0.004), shader)
		mb.set_shader_value("scanlines", f32(0.55), shader)
		mb.set_shader_value("mask", f32(0.35), shader)
		mb.set_shader_value("vignette", f32(0.6), shader)
		mb.set_shader_value("line_count", f32(272), shader)
		mb.set_shader_value("resolution", [2]f32{960, 544}, shader)
	case "dissolve":
		// A ramp over the step, so discard is exercised across the whole range: nothing gone at the start, all of it by the end
		mb.set_shader_value("progress", step_progress, shader)
	case "snow":
		mb.set_shader_value("snow_amount", f32(1.0), shader)
		mb.set_shader_value("snow_depth", f32(0.07), shader)
	case "water":
		mb.set_shader_value("wave_height", f32(0.5), shader)
	case "dreamcast_water":
		mb.set_shader_value("island", [3]f32{0, 0, 3.67}, shader)
	}
}

// A flat square of `size` units facing up, cut into cells x cells squares: the shader moves the vertices, so four corners would have nothing to bob
create_water_grid :: proc(size: f32, cells: int) -> mb.Model {
	side := cells + 1
	vertices := make([]mb.Lit_Vertex, side * side, context.temp_allocator)
	indices := make([]u16, cells * cells * 6, context.temp_allocator)
	for row in 0 ..< side {
		for column in 0 ..< side {
			u := f32(column) / f32(cells)
			v := f32(row) / f32(cells)
			vertices[row * side + column] = {
				vertex = {position = {(u - 0.5) * size, 0, (v - 0.5) * size}, uv = {u, v}, color = {1, 1, 1, 1}},
				normal = {0, 1, 0},
			}
		}
	}
	i := 0
	for row in 0 ..< cells {
		for column in 0 ..< cells {
			top_left := u16(row * side + column)
			top_right := top_left + 1
			bottom_left := top_left + u16(side)
			bottom_right := bottom_left + 1
			indices[i + 0], indices[i + 1], indices[i + 2] = bottom_left, bottom_right, top_right
			indices[i + 3], indices[i + 4], indices[i + 5] = bottom_left, top_right, top_left
			i += 6
		}
	}
	return mb.create_model_from_mesh(vertices, indices)
}

main :: proc() {
	mb.init("shader vita check", 960, 544)
	mb.print("shader vita check: started")
	failures := 0
	checks := 0
	check :: proc(failures: ^int, checks: ^int, name: string, passed: bool) {
		checks^ += 1
		if passed do return
		failures^ += 1
		mb.print("shader vita check: FAIL", name)
	}

	// A shader that is not in the .vpk answers with ok = false and a printed reason, rather than stopping
	missing, missing_ok := mb.load_shader_checked("no_such_shader")
	check(&failures, &checks, "a missing shader is ok = false", missing_ok == false)
	check(&failures, &checks, "a missing shader is the zero Shader", missing.data == nil)

	camera_3d := mb.create_camera_3d({0, 0.5, 4}, {0, 0, 0}, 50)
	camera_shapes := mb.create_camera_3d({0, 4.5, 9}, {0, 1.0, 0})
	camera_sea := mb.create_camera_3d({0, 5, 14}, {0, 0, 0})
	camera_island := mb.create_camera_3d({0, 8, 15}, {0, 0, 0})
	camera_2d := mb.create_camera_2d()
	label_camera := mb.create_screen_camera(544)
	label_font := mb.create_font(mb.DEFAULT_FONT_BYTES, 24, pixels_per_unit = 1)

	checker_pixels: [8 * 8 * 4]u8
	for y in 0 ..< 8 do for x in 0 ..< 8 {
		i := (y * 8 + x) * 4
		orange := (x + y) % 2 == 0
		checker_pixels[i + 0] = 255
		checker_pixels[i + 1] = 140 if orange else 255
		checker_pixels[i + 2] = 0 if orange else 255
		checker_pixels[i + 3] = 255
	}
	checker := mb.create_texture_from_pixels(&checker_pixels, 8, 8, .POINT)
	sprite := mb.create_sprite(checker)
	sprite.scale = {25, 25}
	sprite.position = {330, 0, 0}
	sphere := mb.create_sphere_model(1.0, 32, 64)
	sphere.parts[0].texture = checker
	small_sphere := mb.create_sphere_model(1.2, 32, 64)
	cylinder := mb.create_cylinder_model(0.8, 2.4, 32)
	cube := mb.create_cube_model()
	ground := mb.create_plane_model(30)
	island := mb.create_sphere_model(4.0, 16, 32)
	buoy := mb.create_cube_model()
	sea := create_water_grid(60, WATER_CELLS)
	sea.parts[0].blend = .ALPHA // the engine blends only a part that asks, and the shader's alpha is the see-through shallows
	waves := create_water_grid(40, 128)
	waves.parts[0].blend = .ALPHA
	mb.set_lights({mb.create_directional_light({-1, -2, -1})})

	steps := STEPS
	shader: mb.Shader
	loaded: string
	step_index := -1
	frames := 0
	time: f32 = 0
	timed_seconds: f32 = 0
	timed_frames := 0

	for mb.is_running() {
		mb.poll_events()
		if mb.is_gamepad_pressed(.START) || mb.is_gamepad_pressed(.SELECT) do mb.stop_running()
		delta_time := mb.get_delta_time()

		// Between frames, as destroy_shader and load_shader want
		if step_index < 0 || frames >= FRAMES_PER_STEP {
			if step_index >= 0 {
				mb.print("shader vita check:", steps[step_index].shader, "lighting", steps[step_index].lighting, "stress", steps[step_index].stress, "average ms per frame", fmt.tprintf("%.2f", timed_seconds * 1000 / f32(max(timed_frames, 1))))
			}
			step_index += 1
			frames = 0
			timed_seconds = 0
			timed_frames = 0
			if step_index >= len(steps) do break
			step := steps[step_index]
			if step.shader != loaded || step_index == 0 {
				if shader.data != nil {
					mb.destroy(shader)
					// destroy_shader clears set_shader's current if it was the one destroyed
					check(&failures, &checks, "destroying the current shader clears it", mb.mbi.shader_state.current.data == nil)
					shader = {}
				}
				if step.shader != "" {
					ok: bool
					shader, ok = mb.load_shader_checked(step.shader)
					check(&failures, &checks, fmt.tprintf("load %s", step.shader), ok)
					if ok == false do break
				}
				loaded = step.shader
			}
			mb.print("shader vita check: STEP", step_index + 1, step.shader, "lighting", step.lighting, "stress", step.stress, "started")
		}

		step := steps[step_index]
		time += delta_time
		if shader.data != nil do set_uniforms(shader, step.shader, time, f32(frames) / f32(FRAMES_PER_STEP))

		// What goes through the shader: the water grid or the island in the sea scenes, everything in the others
		on_water := step.shade != "island"
		on_island := step.shade != "water"
		copies := STRESS_COPIES if step.stress else 1
		toward_camera: f32 = 0.05

		mb.render_start()
		mb.clear_background(mb.CORNFLOWER_BLUE if step.scene == .SPHERE else [4]f32{0.55, 0.75, 0.95, 1})
		mb.set_lighting({enabled = step.lighting, ambient = {0.25, 0.25, 0.25, 1}})

		switch step.scene {
		case .SPHERE:
			mb.camera_start(camera_3d)
			mb.set_shader(shader)
			// Back to front toward the camera, so every copy passes the depth test and its fragments are really shaded
			for copy in 0 ..< copies {
				scale: f32 = 2.2 if step.stress else 1
				x: f32 = 0 if step.stress else -1.0
				z := f32(copy) * toward_camera
				mb.render_model(sphere, mb.create_transform({x, 0, z}, mb.calculate_rotation_euler(yaw = time * 0.5), scale))
			}
			mb.set_shader({})
			mb.camera_end()

			mb.camera_start(camera_2d)
			mb.set_shader(shader)
			mb.render_sprite(sprite)
			mb.set_shader({})
			mb.camera_end()
		case .SHAPES:
			mb.camera_start(camera_shapes)
			mb.render_model(ground, [3]f32{0, -0.01, 0}, tint = {0.22, 0.17, 0.12, 1})
			mb.set_shader(shader)
			for copy in 0 ..< copies {
				z := f32(copy) * toward_camera * 2
				mb.render_model(small_sphere, [3]f32{-3.4, 1.2, z}, tint = {0.55, 0.3, 0.25, 1})
				mb.render_model(cylinder, mb.create_transform({0, 1.3, z}, mb.calculate_rotation_euler(roll = 1.1, yaw = time * 0.6)), tint = {0.25, 0.4, 0.55, 1})
				mb.render_model(cube, mb.create_transform({3.4, 1.4, z}, mb.calculate_rotation_euler(pitch = time, yaw = time * 0.4), 1.8), tint = {0.5, 0.45, 0.2, 1})
			}
			mb.set_shader({})
			mb.camera_end()
		case .SEA:
			mb.camera_start(camera_sea)
			mb.set_shader(shader)
			for copy in 0 ..< copies {
				mb.render_model(waves, [3]f32{0, f32(copy) * 0.01, 0}, tint = {0.25, 0.5, 0.75, 1})
			}
			mb.set_shader({})
			mb.render_model(buoy, [3]f32{0, -0.9, 0}, tint = {0.9, 0.3, 0.2, 1})
			mb.camera_end()
		case .SEA_ISLAND:
			mb.camera_start(camera_island)
			island_transform := mb.create_transform({0, -0.4, 0})
			island_transform.scale = {1, 0.25, 1}
			if on_island do mb.set_shader(shader)
			mb.render_model(island, island_transform, tint = {0.95, 0.85, 0.55, 1})
			mb.set_shader({})
			if on_water do mb.set_shader(shader)
			for copy in 0 ..< copies {
				mb.render_model(sea, [3]f32{0, f32(copy) * 0.01, 0})
			}
			mb.set_shader({})
			mb.camera_end()
		}

		mb.camera_start(label_camera)
		mb.render_rectangle({0, 217, 0}, {960, 110}, {0, 0, 0, 0.6})
		shader_name := step.shader if step.shader != "" else "built-in"
		mb.render_text(label_font, fmt.tprintf("Step %v / %v: %v, lighting %v%v", step_index + 1, len(steps), shader_name, step.lighting, ", STRESS" if step.stress else ""), {-470, 245, 0}, {1, 1, 0, 1})
		mb.render_text_wrapped(label_font, step.note, {-470, 225, 0}, 940)
		mb.camera_end()
		mb.render_end()
		// Wait for the GPU, so the frame time is the frame's whole cost and not just the time to queue it: without this the
		// CPU runs ahead and a heavy shader costs nothing on the clock. This is a measuring build, not a game's loop
		gfx.finish()

		if frames == 0 do mb.print("shader vita check: STEP", step_index + 1, step.shader, "drew a frame")
		if frames >= FIRST_TIMED_FRAME {
			timed_seconds += delta_time
			timed_frames += 1
		}
		frames += 1
	}

	mb.print("shader vita check:", checks, "checks, failures", failures)
	mb.print("shader vita check: quit normally")
	if shader.data != nil do mb.destroy(shader)
	mb.destroy_font(label_font)
	mb.destroy(sphere)
	mb.destroy(small_sphere)
	mb.destroy(cylinder)
	mb.destroy(cube)
	mb.destroy(ground)
	mb.destroy(island)
	mb.destroy(buoy)
	mb.destroy(sea)
	mb.destroy(waves)
	mb.destroy_texture(checker)
}
