package mbsc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// The 3DS vertex backend. Each program is assembled with the real `picasso` (devkitPro), and run on the machine of
// pica_machine_test.odin against a plain evaluation of the shader (ir_eval_test.odin).

@(private = "file")
find_picasso :: proc() -> (path: string, found: bool) {
	if value, set := os.lookup_env("PICASSO", context.temp_allocator); set && os.is_file(value) {
		return value, true
	}
	if root, set := os.lookup_env("DEVKITPRO", context.temp_allocator); set {
		for name in ([?]string{"tools/bin/picasso.exe", "tools/bin/picasso"}) {
			candidate := fmt.aprintf("%s/%s", root, name, allocator = context.temp_allocator)
			if os.is_file(candidate) {
				return candidate, true
			}
		}
	}
	for candidate in ([?]string{"C:/devkitPro/tools/bin/picasso.exe", "/opt/devkitpro/tools/bin/picasso"}) {
		if os.is_file(candidate) {
			return candidate, true
		}
	}
	return "", false
}

@(private = "file")
assemble_counter: int

// assemble_pica returns "" when picasso accepts the program, and otherwise its own message.
assemble_pica :: proc(source: string) -> (message: string, ran: bool) {
	assembler, found := find_picasso()
	if found == false {
		return "", false
	}
	directory, directory_error := os.temp_directory(context.temp_allocator)
	if directory_error != nil {
		return fmt.aprintf("no temporary folder: %v", directory_error, allocator = context.temp_allocator), true
	}
	number := sync.atomic_add(&assemble_counter, 1)
	input := fmt.aprintf("%s/mbsc_pica_test_%d.v.pica", directory, number, allocator = context.temp_allocator)
	output := fmt.aprintf("%s/mbsc_pica_test_%d.shbin", directory, number, allocator = context.temp_allocator)
	if write_error := os.write_entire_file(input, source); write_error != nil {
		return fmt.aprintf("can't write %s: %v", input, write_error, allocator = context.temp_allocator), true
	}
	defer os.remove(input)
	defer os.remove(output)

	state, stdout, stderr, run_error := os.process_exec(os.Process_Desc{command = {assembler, "-o", output, input}}, context.temp_allocator)
	if run_error != nil {
		return fmt.aprintf("can't run %s: %v", assembler, run_error, allocator = context.temp_allocator), true
	}
	if state.exit_code != 0 {
		return strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator), true
	}
	return "", true
}

// expect_assembles fails the test when picasso rejects the program.
expect_assembles :: proc(t: ^testing.T, source: string, what: string) {
	message, ran := assemble_pica(source)
	if ran && message != "" {
		fmt.eprintfln("--- %s ---\n%s------------\n%s", what, source, message)
		testing.expectf(t, false, "picasso rejected %s", what)
	}
}

// The built-ins the 3DS vertex unit has no instruction for (MBS-E1, E8 and the fragment-only ones).
@(rodata, private = "file")
NOT_ON_THE_3DS := [?]string {
	"sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "ldexp", "is_nan", "is_inf",
	"transpose", "determinant", "sample", "sample_lod", "sample_bias", "sample_grad", "ddx", "ddy", "fwidth", "discard",
	"dot3_signed", "light_diffuse", "light_specular", // fragment only: the vertex stage must refuse them
}

@(private = "file")
is_missing :: proc(name: string) -> bool {
	for missing in NOT_ON_THE_3DS {
		if missing == name {
			return true
		}
	}
	return false
}

@(test)
every_builtin_the_3ds_has_gives_the_numbers_the_shader_means :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	for case_ in CASES {
		if is_missing(case_.name) {
			// the checker must refuse it, so nobody gets a program that does something else
			_, parsed, message := build_ir_for(in_stage(case_, true), .PICA200)
			defer destroy_parsed(parsed)
			testing.expectf(t, message != "", "`%s` should not check for the 3DS vertex stage", case_.name)
			continue
		}
		source := in_stage(case_, true)
		if expect_pica_matches(t, source, case_.name, {.MIXED, .POSITIVE, .TIES, .WHOLE}) {
			ir, parsed, _ := build_ir_for(source, .PICA200)
			defer destroy_parsed(parsed)
			program, _ := generate_pica(ir, context.temp_allocator)
			expect_assembles(t, program.vertex, fmt.tprintf("the program for `%s`", case_.name))
		}
	}
}

/*
	The engine's shaders for the 3DS are generated and committed, like the PC's HLSL and the Vita's Cg: the runtime
	reads the .tev plan with #load and 3ds_build.bat assembles the .v.pica. Nothing checked them until mesh_lit (G2
	L4-3), so a compiler change could leave the 3DS drawing with an old program. When a shader or the compiler
	changes, run:
	    mbsc matchbox/shaders/<name>.mbs -target:3ds --emit-pica -o:matchbox/shaders/<name>.3ds
*/
@(test)
the_committed_3ds_shaders_are_what_mbsc_writes_now :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	shaders := [?][4]string {
		{"mesh", #load("../../matchbox/shaders/mesh.mbs", string), #load("../../matchbox/shaders/mesh.3ds.v.pica", string), #load("../../matchbox/shaders/mesh.3ds.tev", string)},
		{"mesh_lit", #load("../../matchbox/shaders/mesh_lit.mbs", string), #load("../../matchbox/shaders/mesh_lit.3ds.v.pica", string), #load("../../matchbox/shaders/mesh_lit.3ds.tev", string)},
		{"mesh_vertex_lit", #load("../../matchbox/shaders/mesh_vertex_lit.mbs", string), #load("../../matchbox/shaders/mesh_vertex_lit.3ds.v.pica", string), #load("../../matchbox/shaders/mesh_vertex_lit.3ds.tev", string)},
	}
	for shader in shaders {
		ir, parsed, message := build_ir_for(no_carriage_returns_for_pica(shader[1]), .PICA200)
		defer destroy_parsed(parsed)
		if message != "" {
			testing.expectf(t, false, "%s.mbs: %s", shader[0], message)
			continue
		}
		program, problems := generate_pica(ir, context.temp_allocator)
		testing.expect_value(t, len(problems), 0)
		plan, tev_problems := generate_tev(ir, context.temp_allocator)
		testing.expect_value(t, len(tev_problems), 0)
		table := format_tev(plan, context.temp_allocator)
		testing.expectf(t, program.vertex == no_carriage_returns_for_pica(shader[2]), "matchbox/shaders/%s.3ds.v.pica is out of date; generate it again (see the comment above this test)", shader[0])
		testing.expectf(t, table == no_carriage_returns_for_pica(shader[3]), "matchbox/shaders/%s.3ds.tev is out of date; generate it again (see the comment above this test)", shader[0])
		expect_assembles(t, program.vertex, fmt.tprintf("%s.3ds.v.pica", shader[0]))
	}
}

@(test)
the_spec_shader_runs_the_same_on_the_3ds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := no_carriage_returns_for_pica(#load("../../matchbox/shaders/mesh.mbs", string))
	expect_pica_matches(t, source, "mesh.mbs", {.MIXED, .POSITIVE})
	ir, parsed, _ := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	program, problems := generate_pica(ir, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	expect_assembles(t, program.vertex, "mesh.mbs")
}

@(test)
the_example_shader_runs_the_same_on_the_3ds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := no_carriage_returns_for_pica(#load("../../examples/shader-language/hit_flash.mbs", string))
	expect_pica_matches(t, source, "hit_flash.mbs", {.MIXED, .POSITIVE})
	ir, parsed, _ := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	program, _ := generate_pica(ir, context.temp_allocator)
	expect_assembles(t, program.vertex, "hit_flash.mbs")
}

/*
	The New 3DS LL's GPU hangs on a draw whose vertex shader writes only part of an output
	register (gpu_test4, 2026-11-23), and no emulator shows it. So every write to an output
	register is a whole one: mesh.mbs has a vec2 texcoord0, and hit_flash.mbs its own outputs
*/
@(test)
every_output_register_is_written_whole :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	sources := [?]struct{name, text:string} {
		{"mesh.mbs", #load("../../matchbox/shaders/mesh.mbs", string)},
		{"hit_flash.mbs", #load("../../examples/shader-language/hit_flash.mbs", string)},
	}
	for source in sources {
		ir, parsed, _ := build_ir_for(no_carriage_returns_for_pica(source.text), .PICA200)
		defer destroy_parsed(parsed)
		program, _ := generate_pica(ir, context.temp_allocator)
		writes := 0
		for line in strings.split_lines(program.vertex, context.temp_allocator) {
			fields := strings.fields(strings.trim_space(line), context.temp_allocator)
			// Instructions only: a `.out` line declares the register, it doesn't write it
			if len(fields) < 2 || strings.has_prefix(fields[0], ".") || strings.has_prefix(fields[1], "mbs_out_") == false do continue
			writes += 1
			testing.expectf(t, strings.has_suffix(fields[1], ".xyzw,"), "%s: `%s` writes part of an output register", source.name, strings.trim_space(line))
		}
		testing.expectf(t, writes > 0, "%s: no output writes found", source.name)
	}
}

@(private = "file")
no_carriage_returns_for_pica :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

// small_shader writes a vertex shader that sets `r`, a number, from the given statements, and puts it in the position.
@(private = "file")
small_pica :: proc(declarations: string, body: string) -> string {
	return strings.concatenate(
		{
			declarations,
			"\nVertex_In :: struct {\n\tposition: [3]f32 `attr:\"position\"`,\n\tcolor: [4]f32 `attr:\"color\"`,\n}\n\nVarying :: struct {\n\tposition: [4]f32 `out:\"position\"`,\n\tcolor: [4]f32 `out:\"color\"`,\n}\n\n",
			"vertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\tr: f32\n\t",
			body,
			"\n\toutput.position = [4]f32{r, input.position.x, input.position.y, 1.0}\n\toutput.color = input.color\n\treturn output\n}\n\n",
			"fragment_main :: proc(v: Varying) -> [4]f32 {\n\treturn v.color\n}\n",
		},
		context.temp_allocator,
	)
}

@(private = "file")
expect_small :: proc(t: ^testing.T, name: string, declarations: string, body: string) {
	source := small_pica(declarations, body)
	if expect_pica_matches(t, source, name, {.MIXED, .POSITIVE}) {
		ir, parsed, _ := build_ir_for(source, .PICA200)
		defer destroy_parsed(parsed)
		program, _ := generate_pica(ir, context.temp_allocator)
		expect_assembles(t, program.vertex, name)
	}
}

@(test)
a_for_loop_with_constant_bounds_is_written_out :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_small(t, "weights", "@(uniform) weights: [4]f32\n@(uniform) taps: [4][4]f32\n@(uniform) v4: [4]f32\n",
		"for i in 0..<4 {\n\t\tr += weights[i] * taps[i].y\n\t}\n\tfor j in 1..=2 {\n\t\tr += f32(j) * v4.x\n\t}")
}

@(test)
conditions_take_the_branch_the_shader_means :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "@(uniform) a: f32\n@(uniform) b: f32\n@(uniform) c: f32\n@(uniform) on: bool\n"
	expect_small(t, "if and else", declarations, "if a < b {\n\t\tr = 1.0\n\t} else {\n\t\tr = 2.0\n\t}")
	expect_small(t, "if without else", declarations, "r = 5.0\n\tif a >= 0.5 {\n\t\tr = a * 2.0\n\t}")
	expect_small(t, "and", declarations, "if a < b && b < c {\n\t\tr = 1.0\n\t} else {\n\t\tr = 2.0\n\t}")
	expect_small(t, "or", declarations, "if a < b || c > 1.0 {\n\t\tr = 1.0\n\t} else {\n\t\tr = 2.0\n\t}")
	expect_small(t, "not", declarations, "if !(a < b) {\n\t\tr = 1.0\n\t} else {\n\t\tr = 2.0\n\t}")
	expect_small(t, "a boolean uniform", declarations, "if on {\n\t\tr = a\n\t} else {\n\t\tr = b\n\t}")
	expect_small(t, "nested", declarations, "if a < b {\n\t\tif b < c {\n\t\t\tr = 1.0\n\t\t} else {\n\t\t\tr = 2.0\n\t\t}\n\t} else {\n\t\tr = 3.0\n\t}")
	expect_small(t, "against a constant", declarations, "if 0.5 < a {\n\t\tr = 1.0\n\t} else {\n\t\tr = 2.0\n\t}")
}

@(test)
a_procedure_with_returns_in_both_branches_is_written_in_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "@(uniform) a: f32\n@(uniform) b: f32\n\npick :: proc(x: f32, y: f32) -> f32 {\n\tif x > y {\n\t\treturn x * 2.0\n\t} else {\n\t\treturn y - 1.0\n\t}\n}\n\nsquare :: proc(x: f32) -> f32 {\n\tt := x * x\n\treturn t\n}\n"
	expect_small(t, "calls", declarations, "r = pick(a, b) + pick(b, a) + square(a + b)")
}

@(test)
parts_of_a_vector_can_be_assigned :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_small(t, "swizzle assignment", "@(uniform) a: f32\n@(uniform) b: f32\n@(uniform) v4: [4]f32\n",
		"v: [4]f32\n\tv.zx = [2]f32{a, b}\n\tv.y = v4.w\n\tv.w = 1.0\n\tr = v.x * 2.0 + v.y * 3.0 + v.z * 5.0 + v.w")
}

@(test)
struct_and_array_uniforms_are_split_into_registers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "Light :: struct {\n\tcolor: [3]f32,\n\tstrength: f32,\n}\n\n@(uniform) key: Light\n@(uniform) lights: [2]Light\n"
	expect_small(t, "structs", declarations, "r = key.strength * key.color.y + lights[1].strength + dot(lights[0].color, lights[1].color)")
}

@(test)
matrices_multiply_vectors_both_ways :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "@(uniform) m4: matrix[4, 4]f32\n@(uniform) m3: matrix[3, 3]f32\n@(uniform) m2: matrix[2, 2]f32\n@(uniform) v4: [4]f32\n@(uniform) v3: [3]f32\n@(uniform) v2: [2]f32\n"
	expect_small(t, "matrix times vector", declarations, "r = (m4 * v4).y + (m3 * v3).z + (m2 * v2).x")
	expect_small(t, "vector times matrix", declarations, "r = (v4 * m4).w + (v3 * m3).y + (v2 * m2).x")
}

@(test)
a_matrix_and_an_array_can_be_built_in_the_shader :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "@(uniform) a: f32\n@(uniform) b: f32\n@(uniform) v2: [2]f32\n"
	expect_small(t, "matrix literal", declarations, "m := matrix[2, 2]f32{a, b, 1.0, 2.0}\n\tr = (m * v2).y + (m * v2).x")
	expect_small(t, "array literal", declarations, "list := [3]f32{a, b, 2.0}\n\tlist[1] = list[0] * 2.0\n\tr = list[0] + list[1] + list[2]")
}

@(test)
division_and_long_expressions_work :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "@(uniform) a: f32\n@(uniform) b: f32\n@(uniform) c: f32\n@(uniform) v3: [3]f32\n@(uniform) w3: [3]f32\n"
	expect_small(t, "division", declarations, "r = a / b + v3.x / 4.0 + (v3 / w3).y + (v3 / b).z")
	expect_small(t, "many temporaries", declarations, "r = ((a + b) * (b + c) + (a - c) * (b - a)) * ((a + c) / (b + 4.0)) + length(v3 - w3) * dot(v3, w3)")
}

@(test)
a_variable_lets_go_of_its_register_after_its_last_use :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	declarations := "@(uniform) a: f32\n@(uniform) b: f32\n@(uniform) c: f32\n"
	// 24 variables, each read only by the next one: in one block they need 24 registers if they are kept to the block's end
	body := strings.builder_make(context.temp_allocator)
	strings.write_string(&body, "t0 := a + b\n")
	for index in 1 ..< 24 {
		fmt.sbprintf(&body, "\tt%d := t%d * c + %d.0\n", index, index - 1, index)
	}
	strings.write_string(&body, "\tr = t23 * 0.001\n\tif a < b {\n\t\tr = r + t0\n\t}")
	source := small_pica(declarations, strings.to_string(body))
	ir, parsed, _ := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	_, problems := generate_pica(ir, context.temp_allocator)
	testing.expectf(t, len(problems) == 0, "a chain of short-lived variables should fit: %v", problems)
}
