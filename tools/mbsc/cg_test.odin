package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

// The Cg backend (S4). cg_compile_test.odin runs the real compiler over what it writes; these check what the text
// says, because compiling doesn't show that a matrix is multiplied the right way round.

@(private = "file")
no_carriage_returns :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

@(private = "file")
expect_has :: proc(t: ^testing.T, text: string, piece: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(text, piece), "expected the Cg to contain %q", piece, loc = loc)
}

@(private = "file")
expect_lacks :: proc(t: ^testing.T, text: string, piece: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(text, piece) == false, "the Cg should not contain %q", piece, loc = loc)
}

@(private = "file")
mesh_cg :: proc(t: ^testing.T) -> (programs: Cg_Output, ok: bool) {
	return generate_cg_text(t, no_carriage_returns(#load("../../matchbox/shaders/mesh.mbs", string)), "mesh.mbs")
}

@(test)
a_shader_gives_a_vertex_and_a_fragment_program :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	programs, ok := mesh_cg(t)
	if ok == false {
		return
	}
	// the attributes are plain parameters named after their `attr:` tag, which the runtime looks up by name
	expect_has(t, programs.vertex, "void main(float3 a_position, float2 a_texcoord, float4 a_color,")
	expect_has(t, programs.vertex, "out float4 o_position : POSITION,")
	expect_has(t, programs.vertex, "out float2 o_uv : TEXCOORD0,")
	expect_has(t, programs.vertex, "out float4 o_color : COLOR0)")
	expect_has(t, programs.fragment, "float4 main(float4 i_position : WPOS,")
	expect_has(t, programs.fragment, ") : COLOR {")
	expect_has(t, programs.fragment, "uniform sampler2D tex : TEXUNIT0;")
	// each program holds only what its stage runs
	expect_lacks(t, programs.vertex, "fragment_main")
	expect_lacks(t, programs.vertex, "discard")
	expect_lacks(t, programs.fragment, "vertex_main")
	expect_has(t, programs.fragment, "discard;")
}

@(test)
uniforms_are_globals_named_like_their_hlsl_fields :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	programs, ok := mesh_cg(t)
	if ok == false {
		return
	}
	expect_has(t, programs.vertex, "uniform float4x4 frame_view_projection;")
	expect_has(t, programs.vertex, "uniform float frame_time;")
	expect_has(t, programs.vertex, "uniform float4 render_tint;")
	expect_has(t, programs.vertex, "uniform float render_alpha_cutoff;")
	expect_lacks(t, programs.vertex, "cbuffer")
}

@(test)
matrices_multiply_the_other_way_round :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// `m * v` is `mul(v, m)`: Odin's matrix memory read by Cg is the transposed matrix
	programs, ok := mesh_cg(t)
	if ok == false {
		return
	}
	expect_has(t, programs.vertex, "mul(float4(input.position.x, input.position.y, input.position.z, 1.0), render_model)")
	expect_has(t, programs.vertex, "output.position = mul(world, frame_view_projection);")
}

@(test)
a_matrix_that_isnt_square_has_its_sides_swapped :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := no_carriage_returns(#load("testdata/uniforms.mbs", string))
	programs, ok := generate_cg_text(t, source, "uniforms.mbs")
	if ok == false {
		return
	}
	// matrix[3, 4]f32 has 3 rows of 4; its memory, row by row of Cg, is 4 rows of 3
	expect_has(t, programs.fragment, "uniform float4x3 skew;")
	expect_has(t, programs.fragment, "uniform float3x4 tall;")
	expect_has(t, programs.fragment, "uniform float3x3 rotation;")
	expect_has(t, programs.fragment, "uniform float4x4 bones[2];")
	expect_has(t, programs.fragment, "uniform Light key_light;")
	expect_has(t, programs.fragment, "uniform float4 palette[4];")
}

@(test)
a_matrix_written_out_is_written_transposed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the language writes a matrix row by row; Cg's version of it is the transpose, so the elements swap places
	source := no_carriage_returns(#load("testdata/uniforms.mbs", string))
	source, _ = strings.replace(source, "return sample(albedo, v.uv) * sample(mask, v.uv).x * render.tint * flash", "m := matrix[2, 3]f32{1.0, 2.0, 3.0, 4.0, 5.0, 6.0}\n\treturn [4]f32{(m * [3]f32{1.0, 0.0, 0.0}).x, 0.0, 0.0, 1.0}", 1, context.temp_allocator)
	programs, ok := generate_cg_text(t, source, "uniforms.mbs")
	if ok == false {
		return
	}
	expect_has(t, programs.fragment, "float3x2 m = float3x2(1.0, 4.0, 2.0, 5.0, 3.0, 6.0);")
	expect_has(t, programs.fragment, "mul(float3(1.0, 0.0, 0.0), m)")
}

@(test)
round_goes_to_the_even_neighbour_like_hlsl :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := no_carriage_returns(#load("testdata/uniforms.mbs", string))
	source, _ = strings.replace(source, "return sample(albedo, v.uv) * sample(mask, v.uv).x * render.tint * flash", "return [4]f32{round(flash), round(wide).y, 0.0, 1.0}", 1, context.temp_allocator)
	programs, ok := generate_cg_text(t, source, "uniforms.mbs")
	if ok == false {
		return
	}
	// Cg's own `round` rounds halves away from zero, so the language's `round` is a small function
	expect_has(t, programs.fragment, "float mbs_round(float x) {")
	expect_has(t, programs.fragment, "float4 mbs_round(float4 x) {")
	expect_has(t, programs.fragment, "return r - step(0.5, r - x) * odd;")
	expect_lacks(t, programs.fragment, " round(")
}

@(test)
a_varying_with_no_tag_gets_a_texcoord_on_the_vita :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	programs, ok := generate_cg_text(t, no_carriage_returns(#load("testdata/errors/e06_untagged_varying.mbs", string)), "e06")
	if ok == false {
		return
	}
	expect_has(t, programs.vertex, "out float3 o_normal : TEXCOORD3")
	expect_has(t, programs.fragment, "float3 i_normal : TEXCOORD3")
	expect_cg_compiles(t, programs, "the untagged varying")
}

@(test)
a_helper_that_samples_is_written_for_each_stage :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the PC can't write one copy of this for both stages (MBS-E28); on the Vita each program gets its own text
	source := no_carriage_returns(#load("testdata/errors/e08_sample_in_vertex.mbs", string))
	source, _ = strings.replace(source, "output.color = sample(tex, input.uv)", "output.color = look(input.uv)", 1, context.temp_allocator)
	source, _ = strings.replace(source, "return sample(tex, v.uv) * v.color", "return look(v.uv) * v.color", 1, context.temp_allocator)
	source, _ = strings.replace(source, "vertex_main ::", "look :: proc(uv: [2]f32) -> [4]f32 {\n\treturn sample(tex, uv)\n}\n\nvertex_main ::", 1, context.temp_allocator)
	programs, ok := generate_cg_text(t, source, "both stages")
	if ok == false {
		return
	}
	expect_has(t, programs.vertex, "return tex2Dlod(tex, float4(uv, 0.0, 0.0));")
	expect_has(t, programs.fragment, "return tex2D(tex, uv);")
	expect_cg_compiles(t, programs, "the helper")
}

@(test)
the_shipped_shaders_give_cg_that_compiles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	sources := [?]string {
		no_carriage_returns(#load("../../matchbox/shaders/mesh.mbs", string)),
		no_carriage_returns(#load("../../examples/shader-language/hit_flash.mbs", string)),
		no_carriage_returns(#load("testdata/uniforms.mbs", string)),
		no_carriage_returns(#load("testdata/mesh.mbs", string)),
	}
	for source in sources {
		programs, ok := generate_cg_text(t, source, "a shipped shader")
		if ok {
			expect_cg_compiles(t, programs, "a shipped shader")
		}
	}
}

@(test)
the_committed_mesh_cg_is_what_mbsc_writes_now :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// matchbox/shaders/<name>_v.cg and <name>_f.cg are generated from <name>.mbs and committed, with the .gxp
	// programs psp2cgc makes from them (the Vita runtime loads those). When a shader or the compiler changes, run:
	//     mbsc matchbox/shaders/<name>.mbs -target:vita --emit-cg -o:matchbox/shaders/<name>
	// and compile both with psp2cgc (docs/shader_cg.md) if the program, not just a comment, changed
	Committed_Cg :: struct {
		name: string,
		source: string,
		vertex: string,
		fragment: string,
	}
	shaders := [?]Committed_Cg {
		{"mesh", #load("../../matchbox/shaders/mesh.mbs", string), #load("../../matchbox/shaders/mesh_v.cg", string), #load("../../matchbox/shaders/mesh_f.cg", string)},
		{"mesh_lit", #load("../../matchbox/shaders/mesh_lit.mbs", string), #load("../../matchbox/shaders/mesh_lit_v.cg", string), #load("../../matchbox/shaders/mesh_lit_f.cg", string)},
	}
	for shader in shaders {
		programs, ok := generate_cg_text(t, no_carriage_returns(shader.source), fmt.tprintf("%s.mbs", shader.name))
		if ok == false {
			continue
		}
		testing.expectf(t, programs.vertex == no_carriage_returns(shader.vertex), "matchbox/shaders/%s_v.cg is out of date; generate it again (see the comment in this test)", shader.name)
		testing.expectf(t, programs.fragment == no_carriage_returns(shader.fragment), "matchbox/shaders/%s_f.cg is out of date; generate it again (see the comment in this test)", shader.name)
	}
}

@(test)
the_vita_reflection_names_the_parameters_of_the_programs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := no_carriage_returns(#load("testdata/uniforms.mbs", string))
	ir, parsed, message := build_ir_for(source, .VITA)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	text, problems := generate_reflection_vita(ir, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	expect_has(t, text, "target vita\n")
	expect_has(t, text, "attribute position [3]f32\n")
	expect_has(t, text, "uniform frame_view_projection matrix[4,4]f32 0\n")
	expect_has(t, text, "uniform render_alpha_cutoff f32 0\n")
	// a number, a vector, a matrix, an array, a field of a struct, an element of an array of structs: the names the
	// compiled programs list for them (checked with gxp_info.py on the compiled uniforms shader)
	expect_has(t, text, "uniform flash f32 0\n")
	expect_has(t, text, "uniform rotation matrix[3,3]f32 0\n")
	expect_has(t, text, "uniform weights f32 5\n")
	expect_has(t, text, "uniform key_light.strength f32 0\n")
	expect_has(t, text, "uniform rig.key.color [3]f32 0\n")
	expect_has(t, text, "uniform lights[1].color [3]f32 0\n")
	expect_has(t, text, "texture albedo 0\n")
	expect_has(t, text, "texture mask 1\n")
	// no blocks, registers or sampler: the Vita has none of them
	expect_lacks(t, text, "block ")
	expect_lacks(t, text, "sampler ")
}

@(test)
the_committed_vita_reflection_is_what_mbsc_writes_now :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// regenerate with: mbsc matchbox/shaders/<name>.mbs -target:vita --emit-reflection -o:matchbox/shaders/<name>.vita.refl
	shaders := [?][3]string {
		{"mesh", #load("../../matchbox/shaders/mesh.mbs", string), #load("../../matchbox/shaders/mesh.vita.refl", string)},
		{"mesh_lit", #load("../../matchbox/shaders/mesh_lit.mbs", string), #load("../../matchbox/shaders/mesh_lit.vita.refl", string)},
	}
	for shader in shaders {
		ir, parsed, message := build_ir_for(no_carriage_returns(shader[1]), .VITA)
		defer destroy_parsed(parsed)
		if message != "" {
			testing.expectf(t, false, "%s.mbs: %s", shader[0], message)
			continue
		}
		text, _ := generate_reflection_vita(ir, context.temp_allocator)
		testing.expectf(t, text == no_carriage_returns(shader[2]), "matchbox/shaders/%s.vita.refl is out of date; generate it again (see the comment in this test)", shader[0])
	}
}

// A shader that lights lists the lights uniforms the Vita runtime sets by name, eight slots each, and the material in
// `render` even when the shader left that block out (lit_shader declares neither block)
@(test)
a_lit_shader_lists_the_lights_uniforms_for_the_vita :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	ir, parsed, message := build_ir_for(lit_shader("return light_diffuse(v.quat, v.view) * sample(a, v.uv) + light_specular(v.quat, v.view)"), .VITA)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	text, _ := generate_reflection_vita(ir, context.temp_allocator)
	expect_has(t, text, "uniform lights_ambient [4]f32 0\n")
	expect_has(t, text, "uniform lights_direction [4]f32 8\n")
	expect_has(t, text, "uniform lights_diffuse [4]f32 8\n")
	expect_has(t, text, "uniform lights_specular [4]f32 8\n")
	expect_has(t, text, "uniform render_shininess f32 0\n")
	expect_has(t, text, "uniform render_specular_strength f32 0\n")
}
