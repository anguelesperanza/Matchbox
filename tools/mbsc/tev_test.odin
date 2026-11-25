package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

// The 3DS fragment plan: what mbsc writes for the fragment shapes it supports, and the errors for the ones it can't.

@(private = "file")
fragment_shader :: proc(body: string) -> string {
	return strings.concatenate(
		{
			"@(texture = 0) a: Texture2D\n@(texture = 1) b: Texture2D\n@(uniform) tint: [4]f32\n@(uniform) other: [4]f32\n@(uniform) cut: f32\n",
			"Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n\tuv: [2]f32 `attr:\"texcoord\"`,\n\tcolor: [4]f32 `attr:\"color\"`,\n}\n\n",
			"Varying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n\tuv: [2]f32 `out:\"texcoord0\"`,\n\tuv2: [2]f32 `out:\"texcoord1\"`,\n\tcolor: [4]f32 `out:\"color\"`,\n}\n\n",
			"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\toutput.position = [4]f32{input.position.x, input.position.y, input.position.z, 1.0}\n\toutput.uv = input.uv\n\toutput.uv2 = input.uv\n\toutput.color = input.color\n\treturn output\n}\n\n",
			"fragment_main :: proc(v: Varying) -> [4]f32 {\n\t",
			body,
			"\n}\n",
		},
		context.temp_allocator,
	)
}

@(private = "file")
plan_of :: proc(t: ^testing.T, body: string) -> (text: string, problems: []string) {
	ir, parsed, message := build_ir_for(fragment_shader(body), .PICA200)
	defer destroy_parsed(parsed)
	if message != "" {
		return fmt.tprintf("does not check: %s", message), nil
	}
	plan, found := generate_tev(ir, context.temp_allocator)
	return format_tev(plan, context.temp_allocator), found
}

@(private = "file")
expect_plan :: proc(t: ^testing.T, body: string, want: string) {
	text, problems := plan_of(t, body)
	testing.expectf(t, len(problems) == 0, "problems: %v\n%s", problems, text)
	testing.expectf(t, strings.contains(text, want), "the plan should contain %q:\n%s", want, text)
}

@(private = "file")
expect_problem :: proc(t: ^testing.T, body: string, want: string) {
	text, problems := plan_of(t, body)
	joined := strings.join(problems, "\n", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, want) || strings.contains(text, want), "expected %q, got problems %q and %s", want, joined, text)
}

@(test)
the_spec_shader_gets_one_modulate_stage_and_an_alpha_test :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source, _ := strings.replace_all(#load("../../matchbox/shaders/mesh.mbs", string), "\r\n", "\n", context.temp_allocator)
	ir, parsed, message := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	testing.expect_value(t, message, "")
	plan, problems := generate_tev(ir, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	text := format_tev(plan, context.temp_allocator)
	want := "mbs-tev 2\ntarget 3ds\n\ntexture 0 tex texcoord 0\n\nstage 0 MODULATE TEXTURE0 PRIMARY_COLOR\n\nalphatest GEQUAL uniform render_alpha_cutoff\n"
	testing.expectf(t, text == want, "got:\n%s", text)
}

@(test)
each_operation_maps_to_its_function :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_plan(t, "return v.color + sample(a, v.uv)", "stage 0 ADD PRIMARY_COLOR TEXTURE0")
	expect_plan(t, "return sample(a, v.uv) - v.color", "stage 0 SUBTRACT TEXTURE0 PRIMARY_COLOR")
	expect_plan(t, "return lerp(sample(a, v.uv), sample(b, v.uv2), v.color)", "stage 0 INTERPOLATE TEXTURE1 TEXTURE0 PRIMARY_COLOR")
	expect_plan(t, "return v.color", "stage 0 REPLACE PRIMARY_COLOR")
	expect_plan(t, "return 1.0 - v.color", "stage 0 REPLACE PRIMARY_COLOR!")
	expect_plan(t, "return sample(a, v.uv) * tint", "stage 0 MODULATE TEXTURE0 CONSTANT constant uniform tint")
	expect_plan(t, "return sample(a, v.uv) * [4]f32{0.5, 0.25, 1.0, 1.0}", "constant 0.5 0.25 1 1")
	expect_plan(t, "return saturate(sample(a, v.uv) * v.color)", "stage 0 MODULATE TEXTURE0 PRIMARY_COLOR")
}

@(test)
two_operations_can_share_a_stage_or_chain :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_plan(t, "return sample(a, v.uv) * v.color + tint", "stage 0 MULTIPLY_ADD TEXTURE0 PRIMARY_COLOR CONSTANT")
	expect_plan(t, "return (sample(a, v.uv) + v.color) * tint", "stage 0 ADD_MULTIPLY TEXTURE0 PRIMARY_COLOR CONSTANT")
	// a computed value goes to the next stage as PREVIOUS
	expect_plan(t, "return (sample(a, v.uv) * v.color) * sample(b, v.uv2) - tint", "stage 1")
	expect_plan(t, "m := sample(a, v.uv) * v.color\n\treturn m * tint", "stage 1 MODULATE PREVIOUS CONSTANT")
}

@(test)
helpers_and_names_are_read_through :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := fragment_shader("return glow(sample(a, v.uv), v.color)")
	source, _ = strings.replace_all(source, "fragment_main ::", "glow :: proc(x: [4]f32, y: [4]f32) -> [4]f32 {\n\tm := x * y\n\treturn m\n}\n\nfragment_main ::", context.temp_allocator)
	ir, parsed, message := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	testing.expect_value(t, message, "")
	plan, problems := generate_tev(ir, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	testing.expect(t, strings.contains(format_tev(plan, context.temp_allocator), "stage 0 MODULATE TEXTURE0 PRIMARY_COLOR"))
}

@(test)
the_alpha_test_keeps_the_pixels_the_condition_does_not_discard :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_plan(t, "c := sample(a, v.uv)\n\tif c.a < 0.5 do discard()\n\treturn c", "alphatest GEQUAL 0.5")
	expect_plan(t, "c := sample(a, v.uv)\n\tif c.a <= cut do discard()\n\treturn c", "alphatest GREATER uniform cut")
	expect_plan(t, "c := sample(a, v.uv)\n\tif c.a > 0.25 do discard()\n\treturn c", "alphatest LEQUAL 0.25")
	expect_plan(t, "c := sample(a, v.uv)\n\tif c.a >= 0.25 do discard()\n\treturn c", "alphatest LESS 0.25")
}

@(test)
what_a_stage_cannot_do_is_reported :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// both sides computed: only one value can wait in PREVIOUS
	expect_problem(t, "return (sample(a, v.uv) * v.color) * (sample(b, v.uv2) * tint)", "MBS-E3")
	// seven stages
	expect_problem(t, "return sample(a, v.uv) - v.color - v.color - v.color - v.color - v.color - v.color - v.color", "MBS-E3")
	// two different constants in one stage
	expect_problem(t, "return tint * other", "MBS-E21")
}

// ---- lighting (G2 L2) -----------------------------------------------------------------------------------------------

// A shader with the lighting unit's two varyings, as the lighting plan's L1 test wrote them
@(private = "file")
lit_shader :: proc(body: string) -> string {
	return strings.concatenate(
		{
			"@(texture = 0) a: Texture2D\n@(uniform) model_view: matrix[4, 4]f32\n",
			"Vertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n\tnormal: [3]f32 `attr:\"normal\"`,\n\tuv: [2]f32 `attr:\"texcoord\"`,\n}\n\n",
			"Varying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n\tquat: [4]f32 `out:\"normalquat\"`,\n\tview: [3]f32 `out:\"view\"`,\n\tuv: [2]f32 `out:\"texcoord0\"`,\n}\n\n",
			"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\teye := model_view * [4]f32{input.position.x, input.position.y, input.position.z, 1.0}\n\toutput.position = eye\n\toutput.view = [3]f32{-eye.x, -eye.y, -eye.z}\n\toutput.quat = normal_quaternion(input.normal)\n\toutput.uv = input.uv\n\treturn output\n}\n\n",
			"fragment_main :: proc(v: Varying) -> [4]f32 {\n\t",
			body,
			"\n}\n",
		},
		context.temp_allocator,
	)
}

@(private = "file")
lit_plan_of :: proc(body: string) -> (text: string, problems: []string) {
	ir, parsed, message := build_ir_for(lit_shader(body), .PICA200)
	defer destroy_parsed(parsed)
	if message != "" {
		return fmt.tprintf("does not check: %s", message), nil
	}
	plan, found := generate_tev(ir, context.temp_allocator)
	return format_tev(plan, context.temp_allocator), found
}

@(test)
the_lighting_results_are_sources_and_the_plan_says_how_the_unit_is_set :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// lit texture plus highlight fuses into one stage
	text, problems := lit_plan_of("return light_diffuse(v.quat, v.view) * sample(a, v.uv) + light_specular(v.quat, v.view)")
	testing.expectf(t, len(problems) == 0, "problems: %v\n%s", problems, text)
	want := "mbs-tev 2\ntarget 3ds\n\ntexture 0 a texcoord 0\n\nstage 0 MULTIPLY_ADD FRAGMENT_PRIMARY TEXTURE0 FRAGMENT_SECONDARY\n\nlighting diffuse specular\nlighting_table D0 NH\nlighting_clamp_highlights true\nlighting_two_sided false\nlighting_fresnel secondary_alpha_zero\n"
	testing.expectf(t, text == want, "got:\n%s", text)

	// diffuse alone says so, and a shader that doesn't light has no lighting lines at all
	diffuse, _ := lit_plan_of("return light_diffuse(v.quat, v.view)")
	testing.expectf(t, strings.contains(diffuse, "stage 0 REPLACE FRAGMENT_PRIMARY\n") && strings.contains(diffuse, "lighting diffuse\n"), "got:\n%s", diffuse)
	unlit, _ := lit_plan_of("return sample(a, v.uv)")
	testing.expectf(t, strings.contains(unlit, "lighting") == false, "got:\n%s", unlit)
}

@(test)
lighting_reads_its_varyings_unchanged :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	changed, _ := lit_plan_of("q := v.quat * 0.5\n\treturn light_diffuse(q, v.view)")
	testing.expectf(t, strings.contains(changed, "MBS-E20"), "got:\n%s", changed)
	swapped, _ := lit_plan_of("return light_specular(v.quat, -v.view)")
	testing.expectf(t, strings.contains(swapped, "MBS-E20"), "got:\n%s", swapped)
}
