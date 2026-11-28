package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

// The reflection file: a golden file for the spec's shader, one for a shader with every kind of game uniform, the
// committed copy the engine loads, and the layout rules on small cases.

// build_ir runs the front end on a shader for the PC and returns its intermediate form; `message` says what stopped it.
// The intermediate form points into the parsed shader, so the caller keeps `parsed` until it is done with `ir` and
// then calls destroy_parsed.
build_ir :: proc(source: string) -> (ir: ^IR_Module, parsed: ^Parsed, message: string) {
	return build_ir_for(source, .PC)
}

// build_ir_for is build_ir for another target.
build_ir_for :: proc(source: string, target: Target) -> (ir: ^IR_Module, parsed: ^Parsed, message: string) {
	parsed = parse_shader("test.mbs", source)
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
	}
	module: ^Module
	if len(parsed.diagnostics) == 0 {
		module = build_module(parsed, target)
	}
	if len(parsed.diagnostics) > 0 {
		return nil, parsed, fmt.aprintf("%s %s (line %d)", parsed.diagnostics[0].code, parsed.diagnostics[0].title, parsed.diagnostics[0].label.line, allocator = context.temp_allocator)
	}
	return lower_module(module), parsed, ""
}

@(private = "file")
no_carriage_returns :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

@(private = "file")
reflect :: proc(t: ^testing.T, source: string) -> string {
	ir, parsed, message := build_ir(source)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expectf(t, false, "the shader should check: %s", message)
		return ""
	}
	text, problems := generate_reflection(ir, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	return text
}

@(test)
the_spec_shader_gives_the_golden_reflection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text := reflect(t, no_carriage_returns(#load("testdata/mesh.mbs", string)))
	want := no_carriage_returns(#load("testdata/mesh_pc.refl", string))
	testing.expect(t, text == want, "the reflection of testdata/mesh.mbs differs from testdata/mesh_pc.refl")
	if text != want {
		fmt.eprintfln("--- got ---\n%s--- want ---\n%s", text, want)
	}
}

@(test)
every_kind_of_game_uniform_gives_the_golden_reflection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text := reflect(t, no_carriage_returns(#load("testdata/uniforms.mbs", string)))
	want := no_carriage_returns(#load("testdata/uniforms_pc.refl", string))
	testing.expect(t, text == want, "the reflection of testdata/uniforms.mbs differs from testdata/uniforms_pc.refl")
	if text != want {
		fmt.eprintfln("--- got ---\n%s--- want ---\n%s", text, want)
	}
}

@(test)
the_committed_mesh_reflection_is_what_mbsc_writes_now :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// matchbox/shaders/mesh.pc.refl is generated from mesh.mbs and committed next to the HLSL. When the shader or the
	// compiler changes, run:
	//     mbsc matchbox/shaders/<name>.mbs -target:pc --emit-reflection -o:matchbox/shaders/<name>.pc.refl
	// for mesh and mesh_lit
	shaders := [?][3]string {
		{"mesh", #load("../../matchbox/shaders/mesh.mbs", string), #load("../../matchbox/shaders/mesh.pc.refl", string)},
		{"mesh_lit", #load("../../matchbox/shaders/mesh_lit.mbs", string), #load("../../matchbox/shaders/mesh_lit.pc.refl", string)},
		{"mesh_vertex_lit", #load("../../matchbox/shaders/mesh_vertex_lit.mbs", string), #load("../../matchbox/shaders/mesh_vertex_lit.pc.refl", string)},
	}
	for shader in shaders {
		text := reflect(t, no_carriage_returns(shader[1]))
		testing.expectf(t, text == no_carriage_returns(shader[2]), "matchbox/shaders/%s.pc.refl is out of date; generate it again (see the comment in this test)", shader[0])
	}
}

@(test)
the_engine_blocks_have_the_sizes_of_the_engines_structs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Frame_Constants and Render_Constants in render_windows.odin are 144 and 112 bytes, and the engine checks its own
	// offsets against this file when it starts. `view` starts a new row after `time`, at 80
	text := reflect(t, no_carriage_returns(#load("testdata/mesh.mbs", string)))
	testing.expect(t, strings.contains(text, "block frame 0 144\n"), text)
	testing.expect(t, strings.contains(text, "block render 1 112\n"), text)
	testing.expect(t, strings.contains(text, "value frame time f32 64 4 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value render alpha_cutoff f32 96 4 0 0\n"), text)
}

@(private = "file")
small_shader :: proc(uniforms: string) -> string {
	return strings.concatenate(
		{
			uniforms,
			"\nVertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n}\n\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n}\n\n",
			"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\toutput.position = [4]f32{input.position.x, input.position.y, 0.0, 1.0}\n\treturn output\n}\n\n",
			"fragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn [4]f32{0.0, 0.0, 0.0, 1.0}\n}\n",
		},
		context.temp_allocator,
	)
}

@(test)
a_vector_that_would_cross_a_register_starts_the_next_one :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text := reflect(t, small_shader("@(uniform) a: f32\n@(uniform) b: [4]f32\n@(uniform) c: [3]f32\n@(uniform) d: f32\n"))
	// b can't start at 4 without crossing byte 16, so it goes to 16; c fits after it at 32; d fills the register c leaves
	testing.expect(t, strings.contains(text, "value game a f32 0 4 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value game b [4]f32 16 16 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value game c [3]f32 32 12 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value game d f32 44 4 0 0\n"), text)
	testing.expect(t, strings.contains(text, "block game 2 48\n"), text)
}

@(test)
a_struct_written_inline_is_listed_instead_of_guessed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// found while the declarations are read (MBS-E28), before any backend runs
	_, parsed, message := build_ir(small_shader("@(uniform) light: struct { strength: f32 }\n"))
	defer destroy_parsed(parsed)
	testing.expect(t, strings.contains(message, "MBS-E28 the uniform `light` is a struct written inline"), message)
}

/*
	A shader that calls a light built-in gets the lights block in its reflection, so the engine can check its
	Lights_Block when it starts. The numbers are HLSL's packing of what hlsl.odin declares, worked by hand: the
	ambient row at 0, five arrays of 64 rows of 16 bytes from 16, 1040, 2064, 3088 and 4112, the count at 5136, and the block
	rounded up to 5152. lit_shader declares no `render`; the HLSL declares it for the specular's material, so the
	reflection has to list it or the runtime would never bind it.
*/
@(test)
a_lit_shader_lists_the_lights_block :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text := reflect(t, lit_shader("return light_diffuse(v.quat, v.view) * sample(a, v.uv) + light_specular(v.quat, v.view)"))
	testing.expect(t, strings.contains(text, "block lights 3 5216\n"), text)
	testing.expect(t, strings.contains(text, "value lights ambient [4]f32 0 16 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value lights direction [4]f32 16 1024 64 16\n"), text)
	testing.expect(t, strings.contains(text, "value lights diffuse [4]f32 1040 1024 64 16\n"), text)
	testing.expect(t, strings.contains(text, "value lights specular [4]f32 2064 1024 64 16\n"), text)
	testing.expect(t, strings.contains(text, "value lights position [4]f32 3088 1024 64 16\n"), text)
	testing.expect(t, strings.contains(text, "value lights cone [4]f32 4112 1024 64 16\n"), text)
	testing.expect(t, strings.contains(text, "value lights count i32 5136 4 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value lights ground [4]f32 5152 16 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value lights up [4]f32 5168 16 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value lights fog_color [4]f32 5184 16 0 0\n"), text)
	testing.expect(t, strings.contains(text, "value lights fog_range [4]f32 5200 16 0 0\n"), text)
	testing.expect(t, strings.contains(text, "block render 1 112\n"), text)

	// reached through a procedure of the shader's own, the call still counts
	helper := strings.concatenate({lit_shader("return shade(v)"), "\nshade :: proc(v: Varying) -> [4]f32 {\n\treturn light_diffuse(v.quat, v.view)\n}\n"}, context.temp_allocator)
	testing.expect(t, strings.contains(reflect(t, helper), "block lights 3 5216\n"))

	// and a shader that doesn't light has no lights block
	unlit := reflect(t, lit_shader("return sample(a, v.uv)"))
	testing.expect(t, strings.contains(unlit, "lights") == false, unlit)
}
