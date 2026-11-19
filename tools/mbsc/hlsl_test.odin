package mbsc

import "core:fmt"
import "core:strings"
import "core:testing"

// The HLSL backend: a golden file for the spec's shader, text checks for each rule of the translation, and (on
// Windows) the real compiler's verdict on what comes out.

// generate runs the whole pipeline on a shader and returns its HLSL, or reports what stopped it.
@(private = "file")
generate :: proc(t: ^testing.T, source: string, loc := #caller_location) -> (text: string, problems: []string) {
	parsed := parse_shader("test.mbs", source)
	defer destroy_parsed(parsed)
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
	}
	if len(parsed.diagnostics) > 0 {
		for diagnostic in parsed.diagnostics {
			fmt.eprintfln("    %s %s (line %d)", diagnostic.code, diagnostic.title, diagnostic.label.line)
		}
		testing.expect(t, false, "the shader should check", loc = loc)
		return
	}
	module := build_module(parsed, .PC)
	if len(parsed.diagnostics) > 0 {
		for diagnostic in parsed.diagnostics {
			fmt.eprintfln("    %s %s (line %d)", diagnostic.code, diagnostic.title, diagnostic.label.line)
		}
		testing.expect(t, false, "the shader should check", loc = loc)
		return
	}
	return generate_hlsl(lower_module(module), context.temp_allocator)
}

@(private = "file")
expect_has :: proc(t: ^testing.T, text: string, piece: string, loc := #caller_location) {
	if strings.contains(text, piece) == false {
		fmt.eprintfln("--- hlsl ---\n%s------------", text)
		testing.expectf(t, false, "the HLSL should contain: %s", piece, loc = loc)
	}
}

@(private = "file")
expect_lacks :: proc(t: ^testing.T, text: string, piece: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(text, piece) == false, "the HLSL should not contain: %s", piece, loc = loc)
}

@(private = "file")
no_carriage_returns :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

@(test)
the_spec_shader_gives_the_golden_hlsl :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text, problems := generate(t, no_carriage_returns(#load("testdata/mesh.mbs", string)))
	expect_compiles(t, text)
	testing.expect_value(t, len(problems), 0)
	want := no_carriage_returns(#load("testdata/mesh_pc.hlsl", string))
	testing.expect(t, text == want, "the HLSL of testdata/mesh.mbs differs from testdata/mesh_pc.hlsl")
	if text != want {
		fmt.eprintfln("--- got ---\n%s--- want ---\n%s", text, want)
	}
}

// ---- a shader to change ---------------------------------------------------------------------------------------

@(private = "file")
SOURCE_HEAD :: `Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
	uv:       [2]f32 ` + "`attr:\"texcoord\"`" + `,
	color:    [4]f32 ` + "`attr:\"color\"`" + `,
}

Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
	uv:       [2]f32 ` + "`out:\"texcoord0\"`" + `,
	color:    [4]f32 ` + "`out:\"color\"`" + `,
}

Light :: struct {
	direction: [3]f32,
	strength:  f32,
}

Rig :: struct {
	key:  Light,
	fill: Light,
}

@(uniform = .FRAME) frame: struct { view_projection: matrix[4, 4]f32 }
@(uniform = .DRAW) draw: struct {
	model:   matrix[4, 4]f32,
	tint:    [4]f32,
	uv_rect: [4]f32,
}
@(uniform) flash: f32
@(uniform) count: i32
@(uniform) palette: [4][4]f32
@(uniform) key_light: Light
@(texture = 0) tex: Texture2D
@(texture = 1) mask: Texture2D

LIMIT :: 3

fragment_main :: proc(v: Varying) -> [4]f32 {
	return sample(tex, v.uv) * sample(mask, v.uv).x * v.color
}
`

// A shader with `extras` at the top level and `body` in the vertex stage, before it returns.
@(private = "file")
shader :: proc(body: string, extras := "") -> string {
	return strings.concatenate({SOURCE_HEAD, extras, "\nvertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n", body, "\n\treturn output\n}\n"}, context.temp_allocator)
}

@(test)
engine_blocks_are_written_in_the_engines_full_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the shader declares only three fields of `draw`, and none of `frame.time`; the buffers still hold them all
	text, _ := generate(t, shader("\toutput.position = frame.view_projection * draw.model * [4]f32{input.position.x, 0.0, 0.0, 1.0}"))
	expect_compiles(t, text)
	expect_has(t, text, "cbuffer frame_block : register(b0) {\n    float4x4 frame_view_projection;\n    float frame_time;\n};")
	expect_has(t, text, "cbuffer draw_block : register(b1) {\n    float4x4 draw_model;\n    float4 draw_tint;\n    float4 draw_uv_rect;\n    float draw_alpha_cutoff;\n};")
}

@(test)
game_uniforms_share_one_buffer_after_the_engine_ones :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text, _ := generate(t, shader("\toutput.color.x = flash"))
	expect_compiles(t, text)
	expect_has(t, text, "cbuffer mbs_game : register(b2) {")
	expect_has(t, text, "    float flash;")
	expect_has(t, text, "    int count;")
	expect_has(t, text, "    float4 palette[4];")
	expect_has(t, text, "    Light key_light;")
}

@(test)
textures_get_their_slots_and_share_one_sampler :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text, _ := generate(t, shader("\toutput.color.x = 1.0"))
	expect_compiles(t, text)
	expect_has(t, text, "Texture2D tex : register(t0);")
	expect_has(t, text, "Texture2D mask : register(t1);")
	expect_has(t, text, "SamplerState mbs_sampler : register(s0);")
	expect_has(t, text, "tex.Sample(mbs_sampler, v.uv)")
}

@(test)
matrix_products_use_mul_and_scaling_does_not :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	body := "\tm := frame.view_projection * draw.model\n\tp := m * [4]f32{1.0, 0.0, 0.0, 1.0}\n\tq := [4]f32{1.0, 0.0, 0.0, 1.0} * m\n\ts := m * 2.0\n\tu := 2.0 * m\n\tw := m + m"
	text, _ := generate(t, shader(body))
	expect_compiles(t, text)
	expect_has(t, text, "float4x4 m = mul(frame_view_projection, draw_model);")
	expect_has(t, text, "float4 p = mul(m, float4(1.0, 0.0, 0.0, 1.0));")
	expect_has(t, text, "float4 q = mul(float4(1.0, 0.0, 0.0, 1.0), m);")
	expect_has(t, text, "float4x4 s = m * 2.0;")
	expect_has(t, text, "float4x4 u = 2.0 * m;")
	expect_has(t, text, "float4x4 w = m + m;")
}

@(test)
structs_are_built_with_helpers_and_ordered_by_what_they_contain :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Rig is declared before Light in this shader, and holds two of them
	source := strings.concatenate({"Rig2 :: struct {\n\tkey: Light,\n}\n", shader("\ta := Light{strength = 2.0}\n\tb := Light{{1.0, 2.0, 3.0}, 4.0}\n\tc := Rig{key = a, fill = b}\n\td := Light{}\n\toutput.color.x = c.key.strength + d.strength")}, context.temp_allocator)
	text, _ := generate(t, source)
	expect_compiles(t, text)

	light_at := strings.index(text, "struct Light")
	rig_at := strings.index(text, "struct Rig {")
	rig2_at := strings.index(text, "struct Rig2 {")
	testing.expect(t, light_at >= 0 && light_at < rig_at && light_at < rig2_at, "Light comes before the structs that hold it")

	expect_has(t, text, "Light a = mbs_make_Light((float3)0, 2.0);")
	expect_has(t, text, "Light b = mbs_make_Light(float3(1.0, 2.0, 3.0), 4.0);")
	expect_has(t, text, "Rig c = mbs_make_Rig(a, b);")
	expect_has(t, text, "Light d = (Light)0;")
	expect_has(t, text, "Light mbs_make_Light(float3 direction, float strength) {")
	expect_has(t, text, "Rig mbs_make_Rig(Light key, Light fill) {")
	// a helper is written once, however often it is used
	testing.expect_value(t, strings.count(text, "Light mbs_make_Light("), 1)
}

@(test)
arrays_are_declared_initialised_and_indexed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	body := "\ta := [5]f32{1.0, 2.0, 3.0, 4.0, 5.0}\n\tz: [5]f32\n\ttotal := 0.0\n\tfor i in 0..<5 {\n\t\ttotal += a[i] + z[i]\n\t}\n\toutput.color.x = total + palette[count][0]"
	text, _ := generate(t, shader(body))
	expect_compiles(t, text)
	expect_has(t, text, "float a[5] = { 1.0, 2.0, 3.0, 4.0, 5.0 };")
	expect_has(t, text, "float z[5] = (float[5])0;")
	expect_has(t, text, "palette[count][0]")
}

@(test)
loops_count_up_and_include_the_end_only_when_asked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	body := "\tfor i in 0..<LIMIT {\n\t\toutput.color.x += 1.0\n\t}\n\tfor j in 1..=count {\n\t\toutput.color.y += 1.0\n\t}"
	text, _ := generate(t, shader(body))
	expect_compiles(t, text)
	expect_has(t, text, "for (int i = 0; i < 3; i++) {")
	expect_has(t, text, "for (int j = 1; j <= count; j++) {")
}

@(test)
names_that_hlsl_reserves_are_changed_and_shadowed_ones_are_told_apart :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// `sample` and `point` are HLSL words, `flash` is a uniform, and `x` is declared twice
	body := "\tsample := 1.0\n\tpoint := 2.0\n\tflash := 3.0\n\tx := 1.0\n\tif x > 0.0 {\n\t\tx := 2.0\n\t\toutput.color.x = x + sample + point + flash\n\t}\n\toutput.color.y = x"
	text, _ := generate(t, shader(body))
	expect_compiles(t, text)
	expect_has(t, text, "float mbs_sample = 1.0;")
	expect_has(t, text, "float mbs_point = 2.0;")
	expect_has(t, text, "float flash_")
	expect_has(t, text, "float x = 1.0;")
	expect_has(t, text, "float x_")
	expect_lacks(t, text, "float sample")
}

@(test)
reserved_names_in_structs_and_procedures_are_changed_too :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	extras := "Hit :: struct {\n\tline: f32,\n}\nlerp3 :: proc(a: f32) -> f32 {\n\treturn a\n}\nmin_all :: proc(a: f32) -> f32 {\n\treturn a\n}\n"
	text, _ := generate(t, shader("\th := Hit{line = 1.0}\n\toutput.color.x = h.line + lerp3(1.0) + min_all(2.0)", extras))
	expect_compiles(t, text)
	expect_has(t, text, "float mbs_line;")
	expect_has(t, text, "h.mbs_line")
}

@(test)
numbers_and_operators_are_written_the_way_hlsl_reads_them :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	body := "\tn := -1\n\tm := u32(2)\n\tf := f32(count) / 4.0\n\tok := !(f < 2.0) || true && f >= 1.0\n\tg := 0.1 + 1e-7 + 3.0 + 16777216.0"
	text, _ := generate(t, shader(body))
	expect_compiles(t, text)
	expect_has(t, text, "int n = -1;")
	expect_has(t, text, "uint m = (uint)(2);")
	expect_has(t, text, "float f = ((float)(count)) / 4.0;")
	expect_has(t, text, "bool ok = (!(f < 2.0)) || (true && (f >= 1.0));")
	expect_has(t, text, "0.1")
	expect_has(t, text, "e-07")
	expect_has(t, text, "1.6777216e+07")
}

@(test)
helpers_and_branches_are_written_in_call_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	extras := "outer :: proc(x: f32) -> f32 {\n\tif x > 1.0 {\n\t\treturn inner(x)\n\t} else if x > 0.0 {\n\t\treturn 1.0\n\t}\n\treturn 0.0\n}\ninner :: proc(x: f32) -> f32 {\n\treturn x * 2.0\n}\n"
	text, _ := generate(t, shader("\toutput.color.x = outer(0.5)", extras))
	expect_compiles(t, text)
	inner_at := strings.index(text, "float inner(")
	outer_at := strings.index(text, "float outer(")
	vertex_at := strings.index(text, "Varying vertex_main(")
	testing.expect(t, inner_at >= 0 && inner_at < outer_at && outer_at < vertex_at, "inner, outer, then vertex_main")
	expect_has(t, text, "if (x > 1.0) {")
	expect_has(t, text, "} else {")
}

@(test)
when_is_settled_before_the_hlsl_is_written :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	extras := "pick :: proc() -> f32 {\n\twhen TARGET == .PICA200 {\n\t\treturn 11.0\n\t} else {\n\t\treturn 22.0\n\t}\n}\n"
	text, _ := generate(t, shader("\toutput.color.x = pick()", extras))
	expect_compiles(t, text)
	expect_has(t, text, "return 22.0;")
	expect_lacks(t, text, "11.0")
}

@(test)
what_cant_be_written_is_listed_instead_of_guessed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// an array result and an array handed to a procedure as a literal
	extras := "five :: proc() -> [5]f32 {\n\treturn [5]f32{1.0, 2.0, 3.0, 4.0, 5.0}\n}\nsum :: proc(v: [5]f32) -> f32 {\n\treturn v[0]\n}\n"
	// both are MBS-E28 now, with a position; the backend's own messages are a safety net behind them
	messages := diagnostic_messages(shader("\toutput.color.x = sum([5]f32{1.0, 2.0, 3.0, 4.0, 5.0}) + five()[0]", extras))
	testing.expect(t, strings.contains(messages, "`five` returns an array"), messages)
	testing.expect(t, strings.contains(messages, "an array written out can't be passed"), messages)
}

@(test)
the_shipped_shaders_give_hlsl_that_compiles :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	sources := [?]string {
		no_carriage_returns(#load("../../matchbox/shaders/mesh.mbs", string)),
		no_carriage_returns(#load("../../examples/shader-language/hit_flash.mbs", string)),
	}
	for source in sources {
		text, problems := generate(t, source)
		testing.expect_value(t, len(problems), 0)
		expect_compiles(t, text)
	}
}

@(test)
mod_and_the_approximate_trig_become_small_functions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	text, problems := generate(t, shader("\toutput.color.x = mod(flash, 2.0) + mod(input.position, flash).x + sin_approx(flash) + cos_approx(input.position).y"))
	testing.expect_value(t, len(problems), 0)
	expect_compiles(t, text)
	// `mod` follows the sign of the divisor, like Odin's; HLSL's `fmod` follows the dividend's
	expect_has(t, text, "float mbs_mod(float a, float b) {\n    return a - b * floor(a / b);\n}")
	expect_has(t, text, "float3 mbs_mod(float3 a, float b) {\n    return a - b * floor(a / b);\n}")
	expect_has(t, text, "float mbs_sin_approx(float x) {")
	expect_has(t, text, "float3 mbs_cos_approx(float3 x) {")
	expect_lacks(t, text, "fmod(")
}

@(test)
dot3_signed_is_four_times_the_dot_of_the_recentred_colours :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// it's a fragment-stage built-in: the vertex stage can't call it, so it goes in the fragment shader
	source, _ := strings.replace_all(shader("\toutput.color.x = 1.0"), "return sample(tex, v.uv) * sample(mask, v.uv).x * v.color", "return [4]f32{dot3_signed(v.color, v.color), dot3_signed(key_light.direction, key_light.direction), 0.0, 1.0}", context.temp_allocator)
	text, problems := generate(t, source)
	testing.expect_value(t, len(problems), 0)
	expect_compiles(t, text)
	expect_has(t, text, "(4.0 * dot(v.color.xyz - 0.5, v.color.xyz - 0.5))")
	expect_has(t, text, "(4.0 * dot(key_light.direction - 0.5, key_light.direction - 0.5))")
}

// diagnostic_messages is the code and title of every error the checks give a shader for the PC.
@(private = "file")
diagnostic_messages :: proc(source: string) -> string {
	parsed := parse_shader("test.mbs", source)
	defer destroy_parsed(parsed)
	check_subset(parsed)
	build_module(parsed, .PC)
	builder := strings.builder_make(context.temp_allocator)
	for diagnostic in parsed.diagnostics {
		fmt.sbprintfln(&builder, "%s: %s", diagnostic.code, diagnostic.title)
	}
	return strings.to_string(builder)
}

@(test)
sampling_in_the_vertex_stage_gets_an_explicit_level :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the vertex stage has no derivatives to pick a mip level, so HLSL needs one given: level 0
	text, problems := generate(t, shader("\toutput.color = sample(tex, input.uv)"))
	testing.expect_value(t, len(problems), 0)
	expect_compiles(t, text)
	expect_has(t, text, "tex.SampleLevel(mbs_sampler, input.uv, 0.0)")
	// the fragment stage of the same shader samples as usual
	expect_has(t, text, "tex.Sample(mbs_sampler, v.uv)")
}

@(test)
a_helper_that_samples_in_both_stages_is_listed_instead_of_guessed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	extras := "look :: proc(uv: [2]f32) -> [4]f32 {\n\treturn sample(tex, uv)\n}\n"
	source, _ := strings.replace_all(shader("\toutput.color = look(input.uv)", extras), "return sample(tex, v.uv) * sample(mask, v.uv).x * v.color", "return look(v.uv)", context.temp_allocator)
	messages := diagnostic_messages(source)
	testing.expect(t, strings.contains(messages, "MBS-E28: `look` samples a texture and runs in both stages"), messages)
}

@(test)
the_committed_mesh_hlsl_is_what_mbsc_writes_now :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// matchbox/shaders/mesh.pc.hlsl is generated from mesh.mbs and committed, so the engine needs no tool at build
	// time. When the shader or the compiler changes, run:
	//     mbsc matchbox/shaders/mesh.mbs -target:pc --emit-hlsl -o:matchbox/shaders/mesh.pc.hlsl
	text, problems := generate(t, no_carriage_returns(#load("../../matchbox/shaders/mesh.mbs", string)))
	testing.expect_value(t, len(problems), 0)
	committed := no_carriage_returns(#load("../../matchbox/shaders/mesh.pc.hlsl", string))
	testing.expect(t, text == committed, "matchbox/shaders/mesh.pc.hlsl is out of date; generate it again (see the comment in this test)")
}
