package mbsc

import "core:fmt"
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
render_light :: proc(scene: Light_Scene, quat: [4]f32, view: [3]f32, result: string) -> (pixel: [4]f32, message: string) {
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
	// the lights block: the ambient colour, then 8 directions, 8 diffuse colours, 8 specular colours, a [4]f32 each
	lights := make([]f32, 4 + 3 * 8 * 4, context.temp_allocator)
	ambient := scene.ambient
	copy(lights[0:3], ambient[:])
	for slot in 0 ..< 8 {
		direction, diffuse, specular := scene.direction[slot], scene.diffuse[slot], scene.specular[slot]
		copy(lights[4 + slot * 4:], direction[:])
		copy(lights[4 + 32 + slot * 4:], diffuse[:])
		copy(lights[4 + 64 + slot * 4:], specular[:])
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
		scene, quat, view := create_light_case(&random, 1 + case_index % 8)
		want := calculate_light_reference(scene, quat, view)
		diffuse, diffuse_message := render_light(scene, quat, view, "light_diffuse(v.quat, v.view)")
		specular, specular_message := render_light(scene, quat, view, "light_specular(v.quat, v.view)")
		if diffuse_message != "" || specular_message != "" {
			testing.expectf(t, false, "%s%s", diffuse_message, specular_message)
			return
		}
		testing.expectf(t, diffuse.w == 1 && specular.w == 1, "alpha is not 1: %v %v", diffuse, specular)
		for lane in 0 ..< 3 {
			worst = max(worst, abs(f64(diffuse[lane]) - want.diffuse[lane]), abs(f64(specular[lane]) - want.specular[lane]))
		}
	}
	testing.expectf(t, worst <= 1e-4, "the HLSL is %v from the formula", worst)
	fmt.printfln("light HLSL: worst %.7f", worst)
}
