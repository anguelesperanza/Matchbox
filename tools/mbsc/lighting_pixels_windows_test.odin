package mbsc

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

// The light built-ins as the PC runs them: mbsc's HLSL on Direct3D 11's software device, against the formula
// (lighting_model_test.odin). The quaternion and the view vector reach the pixel through varyings, as they do in a
// real shader, set the same at every corner so the interpolated value is the one given.

@(private = "file")
LIT_SHADER :: `@(uniform) quat_in: [4]f32
@(uniform) view_in: [4]f32

Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
}

Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
	quat: [4]f32 ` + "`out:\"normalquat\"`" + `,
	view: [3]f32 ` + "`out:\"view\"`" + `,
}

vertex_main :: proc(input: Vertex_In) -> Varying {
	output: Varying
	output.position = [4]f32{input.position.x, input.position.y, 0.0, 1.0}
	output.quat = quat_in
	output.view = view_in.xyz
	return output
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	return RESULT
}
`

@(private = "file")
render_light :: proc(scene: Light_Scene, count: int, quat: [4]f32, view: [3]f32, result: string, scene_rows := [4][4]f32{}) -> (pixel: [4]f32, message: string) {
	source, _ := strings.replace(LIT_SHADER, "RESULT", result, 1, context.temp_allocator)
	parsed := parse_shader("lit.mbs", source)
	defer destroy_parsed(parsed)
	module := build_module(parsed, .PC)
	if len(parsed.diagnostics) > 0 {
		return {}, fmt.tprintf("%s %s (line %d)", parsed.diagnostics[0].code, parsed.diagnostics[0].title, parsed.diagnostics[0].label.line)
	}
	hlsl, problems := generate_hlsl(lower_module(module), context.temp_allocator)
	if len(problems) > 0 {
		return {}, strings.join(problems, "\n", context.temp_allocator)
	}

	// the render block's material: shininess and specular strength follow model, tint, uv_rectangle, alpha_cutoff
	draw := make([]f32, 28, context.temp_allocator)
	draw[25] = scene.shininess
	draw[26] = scene.specular_strength
	// the lights block: the ambient colour, then the slots' directions, diffuse colours, specular colours, positions and cones, a [4]f32
	// each, then the count as an int in the next row
	slots := get_max_lights(.PC)
	lights := make([]f32, 4 + 5 * slots * 4 + 4 + 16, context.temp_allocator) // the last 16: the four scene rows, ground, up, fog colour, fog range
	ambient := scene.ambient
	copy(lights[0:3], ambient[:])
	for slot in 0 ..< 8 {
		direction, diffuse, specular := scene.direction[slot], scene.diffuse[slot], scene.specular[slot]
		copy(lights[4 + slot * 4:], direction[:])
		lights[4 + slot * 4 + 3] = scene.extent[slot]
		copy(lights[4 + slots * 4 + slot * 4:], diffuse[:])
		copy(lights[4 + 2 * slots * 4 + slot * 4:], specular[:])
		position := [4]f32{scene.position[slot].x, scene.position[slot].y, scene.position[slot].z, f32(scene.kind[slot])}
		copy(lights[4 + 3 * slots * 4 + slot * 4:], position[:])
		cone := scene.cone[slot]
		copy(lights[4 + 4 * slots * 4 + slot * 4:], cone[:])
	}
	// A bright light in the first slot past the count, shining from where the eye is (so on the side the normal
	// faces): it would show in both results if the loops read past `lights_count`
	past := count
	view_direction := view
	copy(lights[4 + past * 4:], view_direction[:])
	copy(lights[4 + slots * 4 + past * 4:], []f32{1, 1, 1})
	copy(lights[4 + 2 * slots * 4 + past * 4:], []f32{1, 1, 1})
	lights[4 + 5 * slots * 4] = transmute(f32)i32(count)
	for row, index in scene_rows {
		row := row
		copy(lights[4 + 5 * slots * 4 + 4 + index * 4:], row[:])
	}
	game := make([]f32, 8, context.temp_allocator)
	quat_in, view_in := quat, view
	copy(game[0:4], quat_in[:])
	copy(game[4:7], view_in[:])

	vertices := [?]f32{-1, -1, 0, 0, 0, 0, 0, 0, 0, 3, -1, 0, 0, 0, 0, 0, 0, 0, -1, 3, 0, 0, 0, 0, 0, 0, 0}
	indices := [?]u16{0, 1, 2}
	pixels, render_message := gpu_render(
		Gpu_Job {
			hlsl = hlsl,
			vertex_entry = "vertex_main",
			pixel_entry = "fragment_main",
			width = 1,
			height = 1,
			vertices = vertices[:],
			indices = indices[:],
			draw = draw,
			game = game,
			lights = lights,
		},
	)
	if render_message != "" {
		return {}, render_message
	}
	return pixel_at(pixels, 1, 0, 0), ""
}

// The tolerance is float arithmetic, not 8-bit: the device and the formula do the same sums in f32 and f64
@(test)
the_generated_hlsl_lights_as_the_formula_says :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	random := Light_Random{state = 11}
	worst: f64
	for case_index in 0 ..< 24 {
		count := 1 + case_index % 8
		// every third case mixes suns, point lights and spots
		scene, quat, view := create_light_case(&random, count, case_index % 3 == 2)
		want := calculate_light_reference(scene, quat, view)
		diffuse, diffuse_message := render_light(scene, count, quat, view, "light_diffuse(v.quat, v.view)")
		specular, specular_message := render_light(scene, count, quat, view, "light_specular(v.quat, v.view)")
		if diffuse_message != "" || specular_message != "" {
			testing.expectf(t, false, "%s%s", diffuse_message, specular_message)
			return
		}
		testing.expectf(t, diffuse.w == 1 && specular.w == 0, "the diffuse's alpha is not 1 or the specular's not 0: %v %v", diffuse, specular)
		for lane in 0 ..< 3 {
			worst = max(worst, abs(f64(diffuse[lane]) - want.diffuse[lane]), abs(f64(specular[lane]) - want.specular[lane]))
		}
	}
	testing.expectf(t, worst <= 1e-4, "the HLSL is %v from the formula", worst)
	fmt.printfln("light HLSL: worst %.7f", worst)
}

// The PC's scene settings, with numbers worked by hand: hemisphere ambient, exposure, tonemaps and fog
@(test)
the_scene_settings_do_what_they_say :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// rows: ground, up, fog colour, fog range (start, 1 / length, exposure, tonemap kind)
	none := [4][4]f32{{}, {}, {}, {0, 1, 1, 0}}
	front := [4]f32{0, 0, 0, 1} // the normal is +Z in eye space
	eye := [3]f32{0, 0, 4}

	near :: proc(t: ^testing.T, got: [4]f32, want: [4]f32, what: string) {
		for lane in 0 ..< 4 {
			testing.expectf(t, abs(got[lane] - want[lane]) < 0.002, "%s: got %v, want %v", what, got, want)
			if abs(got[lane] - want[lane]) >= 0.002 do return
		}
	}

	// no settings: the colour comes out as it went in (the clamp only)
	got, message := render_light({}, 0, front, eye, "light_finish([4]f32{0.25, 0.5, 2.0, 0.5}, v.view)", none)
	testing.expect_value(t, message, "")
	near(t, got, {0.25, 0.5, 1, 0.5}, "no settings")

	// exposure 2 doubles it
	got, message = render_light({}, 0, front, eye, "light_finish([4]f32{0.125, 0.25, 0.5, 1.0}, v.view)", [4][4]f32{{}, {}, {}, {0, 1, 2, 0}})
	near(t, got, {0.25, 0.5, 1, 1}, "exposure 2")

	// Reinhard: x / (1 + x), so 1 is a half and 3 is three quarters
	got, message = render_light({}, 0, front, eye, "light_finish([4]f32{1.0, 3.0, 0.0, 1.0}, v.view)", [4][4]f32{{}, {}, {}, {0, 1, 1, 1}})
	near(t, got, {0.5, 0.75, 0, 1}, "Reinhard")

	// ACES (Narkowicz): 1 is 2.54 / 3.16
	got, message = render_light({}, 0, front, eye, "light_finish([4]f32{1.0, 0.0, 0.0, 1.0}, v.view)", [4][4]f32{{}, {}, {}, {0, 1, 1, 2}})
	near(t, got, {2.54 / 3.16, 0, 0, 1}, "ACES")

	// AgX has no number worked by hand here: it must rise with the light and stay on the screen
	previous: f32 = -1
	for light in ([?]f32{0.02, 0.18, 0.6, 1.5, 6}) {
		text := fmt.tprintf("light_finish([4]f32{{%.3f, %.3f, %.3f, 1.0}}, v.view)", light, light, light)
		got, message = render_light({}, 0, front, eye, text, [4][4]f32{{}, {}, {}, {0, 1, 1, 3}})
		testing.expect_value(t, message, "")
		testing.expectf(t, got.x > previous && got.x >= 0 && got.x <= 1, "AgX: %v after %v", got.x, previous)
		previous = got.x
	}

	// Fog: nothing before the start, all of it at the end, half way a straight blend, and the alpha is the colour's own
	fog_color := [4]f32{0, 0, 1, 1}
	for fog_case in ([?][2]f32{{0, 0}, {2, 0}, {4, 0.5}, {6, 1}, {9, 1}}) {
		rows := [4][4]f32{{}, {}, fog_color, {2, 0.25, 1, 0}} // from 2 to 6 units
		got, message = render_light({}, 0, front, {0, 0, fog_case.x == 0 ? 1 : fog_case.x}, "light_finish([4]f32{1.0, 0.0, 0.0, 0.5}, v.view)", rows)
		amount := fog_case.y
		near(t, got, {1 - amount, 0, amount, 0.5}, fmt.tprintf("fog at %v", fog_case.x))
	}

	// Hemisphere: a normal facing the sky gets the sky's colour, one facing the ground the ground's, sideways half of each
	sky := [3]f32{1, 0, 0}
	ground := [4]f32{0, 0, 1, 0}
	scene := Light_Scene{ambient = sky}
	for up_case in ([?]struct {up: [4]f32, want: [4]f32}{{{0, 0, 1, 1}, {1, 0, 0, 1}}, {{0, 0, -1, 1}, {0, 0, 1, 1}}, {{0, 1, 0, 1}, {0.5, 0, 0.5, 1}}, {{0, 0, -1, 0}, {1, 0, 0, 1}}}) {
		got, message = render_light(scene, 0, front, eye, "light_diffuse(v.quat, v.view)", [4][4]f32{ground, up_case.up, {}, {0, 1, 1, 0}})
		testing.expect_value(t, message, "")
		near(t, got, up_case.want, fmt.tprintf("hemisphere with up %v", up_case.up))
	}

	// A tonemap leaves the light above 1 for the curve, where with none it is clamped first
	bright := Light_Scene{ambient = {3, 3, 3}}
	got, message = render_light(bright, 0, front, eye, "light_diffuse(v.quat, v.view)", none)
	near(t, got, {1, 1, 1, 1}, "clamped")
	got, message = render_light(bright, 0, front, eye, "light_diffuse(v.quat, v.view)", [4][4]f32{{}, {}, {}, {0, 1, 1, 1}})
	near(t, got, {3, 3, 3, 1}, "left bright for a tonemap")
}

// Area lights, with numbers worked by hand: a rectangle and a disk facing -Z from the origin, a pixel looking up at them from z = -3
@(test)
area_lights_shine_from_their_nearest_point_and_their_front_only :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// a surface whose normal is +Z, toward the light; the pixel sits at `at`, which the shader is told as the view vector negated
	front := [4]f32{0, 0, 0, 1}
	fade :: proc(distance: f32) -> f32 {return 1 / (1 + distance * (0.09 + 0.032 * distance))}

	area := proc(kind: int, half_width, half_height: f32) -> Light_Scene {
		scene: Light_Scene
		scene.kind[0] = kind // 3 a rectangle, 4 a disk
		scene.direction[0] = {0, 0, -1} // faces -Z
		scene.extent[0] = half_height
		scene.position[0] = {0, 0, 0}
		scene.cone[0] = {1, 0, 0, half_width} // right is +X
		scene.diffuse[0] = {1, 1, 1}
		return scene
	}
	check :: proc(t: ^testing.T, scene: Light_Scene, at: [3]f32, want: f32, what: string) {
		got, message := render_light(scene, 1, {0, 0, 0, 1}, -at, "light_diffuse(v.quat, v.view)")
		testing.expect_value(t, message, "")
		testing.expectf(t, abs(got.x - want) < 0.002, "%s: got %v, want %v", what, got.x, want)
	}

	rectangle := area(3, 1, 0.5)
	check(t, rectangle, {0, 0, -3}, fade(3), "straight in front of the rectangle")
	// beside it: the nearest point is its edge (1, 0, 0), 5 away, and the light comes 3/5 of the way along the normal
	check(t, rectangle, {5, 0, -3}, 0.6 * fade(5), "past the rectangle's side")
	// above it, in the rectangle's short direction: the nearest point is (0, +-0.5), so a pixel 2 off is 1.5 off it
	check(t, rectangle, {0, 2, -3}, 3 / math.sqrt(f32(3 * 3 + 1.5 * 1.5)) * fade(math.sqrt(f32(3 * 3 + 1.5 * 1.5))), "past the rectangle's end")
	check(t, rectangle, {0, 0, 3}, 0, "behind the rectangle")

	disk := area(4, 1, 0)
	check(t, disk, {0.7, 0.7, -3}, fade(3), "in front of the disk, inside its radius")
	// outside: the nearest point is on the rim, a unit from the centre toward the pixel
	rim := [3]f32{0.7071068, 0.7071068, 0}
	to := [3]f32{rim.x - 1.4, rim.y - 1.4, 3}
	distance := math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
	check(t, disk, {1.4, 1.4, -3}, 3 / distance * fade(distance), "past the disk's rim")
	check(t, disk, {0, 0, 3}, 0, "behind the disk")
}
