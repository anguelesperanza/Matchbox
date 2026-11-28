package mbsc

import "core:strings"
import "core:testing"

/*
	The lights block a shader declares itself (G2 L5-0), and LIGHT_SLOT_COUNT. testdata/vertex_lights.mbs reads the
	block in the vertex stage, which is what per-vertex lighting does, looping over every slot.
*/

@(private = "file")
VERTEX_LIGHTS :: #load("testdata/vertex_lights.mbs", string)

@(private = "file")
without_carriage_returns :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

// The same source sizes the block and its loop for each target: 64 slots on PC, 8 on the handhelds
@(test)
light_slot_count_is_the_targets :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := without_carriage_returns(VERTEX_LIGHTS)
	ir, parsed, message := build_ir_for(source, .PC)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	text, problems := generate_hlsl(ir, context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	expect_compiles(t, text)
	testing.expect_value(t, strings.count(text, "cbuffer mbs_lights_block : register(b3)"), 1)
	testing.expectf(t, strings.contains(text, "float4 lights_direction[64];"), "got:\n%s", text)
	// the built-ins' functions come only with a built-in
	testing.expect(t, strings.contains(text, "mbs_light_diffuse") == false)

	reflection, _ := generate_reflection(ir, context.temp_allocator)
	testing.expectf(t, strings.contains(reflection, "block lights 3 5296\n"), "got:\n%s", reflection)

	pica_ir, pica_parsed, pica_message := build_ir_for(without_carriage_returns(VERTEX_LIGHTS), .PICA200)
	defer destroy_parsed(pica_parsed)
	if pica_message != "" {
		testing.expect(t, false, pica_message)
		return
	}
	program, pica_problems := generate_pica(pica_ir, context.temp_allocator)
	testing.expect_value(t, len(pica_problems), 0)
	testing.expectf(t, strings.contains(program.vertex, ".fvec lights_direction[8]"), "got:\n%s", program.vertex)
	// unrolled: each slot read by its own constant index, the last one 7
	testing.expect(t, strings.contains(program.vertex, "lights_direction[7]"))
	expect_assembles(t, program.vertex, "vertex_lights.mbs")
}

// The PICA program computes what the IR interpreter does, on random lights and normals
@(test)
a_vertex_stage_reading_the_lights_runs_the_same_on_the_3ds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	expect_pica_matches(t, without_carriage_returns(VERTEX_LIGHTS), "vertex_lights.mbs", {.MIXED, .POSITIVE})
}

// The Vita's Cg declares the block in the vertex program, where it is read, and psp2cgc compiles both programs
@(test)
the_vita_vertex_program_reads_the_lights :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	programs, ok := generate_cg_text(t, without_carriage_returns(VERTEX_LIGHTS), "vertex_lights.mbs")
	if ok == false {
		return
	}
	testing.expectf(t, strings.contains(programs.vertex, "uniform float4 lights_direction[8];"), "got:\n%s", programs.vertex)
	testing.expect(t, strings.contains(programs.vertex, "mbs_light_diffuse") == false)
	expect_cg_compiles(t, programs, "vertex_lights.mbs")
}

// A shader that declares the block and calls a built-in gets one block, which both read
@(test)
a_declared_block_and_a_built_in_share_one_block :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := strings.concatenate({lit_shader("return light_diffuse(v.quat, v.view)"), "\n@(uniform = .LIGHTS) lights: struct { ambient: [4]f32 }\n"}, context.temp_allocator)
	ir, parsed, message := build_ir_for(source, .PC)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	text, _ := generate_hlsl(ir, context.temp_allocator)
	expect_compiles(t, text)
	testing.expect_value(t, strings.count(text, "cbuffer mbs_lights_block"), 1)
	testing.expect_value(t, strings.count(text, "float4 lights_ambient;"), 1)
}

// What a shader gets wrong about the block is named, with the fix
@(test)
a_wrong_lights_block_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	Case :: struct {
		name: string,
		block: string,
		code: string,
		says: string,
	}
	cases := [?]Case {
		{"named otherwise", "@(uniform = .LIGHTS) sun: struct { ambient: [4]f32 }", "MBS-E13", "must be named `lights`"},
		{"a fixed length", "@(uniform = .LIGHTS) lights: struct { direction: [8][4]f32 }", "MBS-E13", "has the wrong type"},
		{"a field it hasn't", "@(uniform = .LIGHTS) lights: struct { shadow: [LIGHT_SLOT_COUNT][4]f32 }", "MBS-E18", "has no field `shadow`"},
		{"the count declared again", "LIGHT_SLOT_COUNT :: 4", "", ""},
	}
	for test_case in cases {
		source := strings.concatenate({lit_shader("return v.quat"), "\n", test_case.block, "\n"}, context.temp_allocator)
		parsed := parse_shader("test.mbs", source)
		defer destroy_parsed(parsed)
		if parsed.has_syntax_errors == false {
			check_subset(parsed)
		}
		if len(parsed.diagnostics) == 0 {
			build_module(parsed, .PC)
		}
		testing.expectf(t, len(parsed.diagnostics) > 0, "%s: no error", test_case.name)
		if len(parsed.diagnostics) == 0 || test_case.code == "" {
			continue
		}
		first := parsed.diagnostics[0]
		testing.expectf(t, first.code == test_case.code, "%s: got %s %s", test_case.name, first.code, first.title)
		testing.expectf(t, strings.contains(first.title, test_case.says), "%s: got %q", test_case.name, first.title)
	}
}
