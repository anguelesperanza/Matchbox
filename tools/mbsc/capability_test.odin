package mbsc

import "core:strings"
import "core:testing"

// S7: what each target can do, and the report of `mbsc --check`. One error at a time is in errors_test.odin; this
// is the other side (what the 3DS does accept) and the report.

@(private = "file")
no_carriage_returns :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

@(private = "file")
messages_for :: proc(source: string, target: Target) -> string {
	result := check_for_target("test.mbs", source, target)
	return strings.join(result.messages[:], "\n", context.temp_allocator)
}

@(private = "file")
mesh_source :: proc() -> string {
	return no_carriage_returns(#load("../../matchbox/shaders/mesh.mbs", string))
}

@(private = "file")
BASE := #load("testdata/errors/e01_vertex_builtin.mbs", string)

@(test)
what_the_3ds_can_do_passes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// the approximate trig, a matrix times a vector, a loop with its counter as an index, two comparisons, and
	// the alpha test
	source, _ := strings.replace(
		no_carriage_returns(BASE),
		"\toutput.color = input.color * sin(input.position.x)\n",
		"\ttotal := 0.0\n\tfor i in 0..<4 {\n\t\ttotal += weights[i]\n\t}\n\tif input.uv.x > 0.0 && input.uv.y > 0.0 {\n\t\ttotal += 1.0\n\t}\n\toutput.color = input.color * (sin_approx(input.position.x) + total)\n",
		1,
		context.temp_allocator,
	)
	source, _ = strings.replace(source, "@(texture = 0) tex: Texture2D\n", "@(texture = 0) tex: Texture2D\n@(uniform) weights: [4]f32\n", 1, context.temp_allocator)
	source, _ = strings.replace(source, "return sample(tex, v.uv) * v.color", "color := sample(tex, v.uv) * v.color\n\tif color.a < draw.alpha_cutoff {\n\t\tdiscard()\n\t}\n\treturn color", 1, context.temp_allocator)

	for target in Target {
		testing.expect_value(t, messages_for(source, target), "")
	}
}

@(test)
the_3ds_limits_do_not_apply_to_the_other_targets :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// `sin` in a vertex shader, a texture read there, whole-number arithmetic: all fine on PC and Vita
	source, _ := strings.replace(
		no_carriage_returns(BASE),
		"\toutput.color = input.color * sin(input.position.x)\n",
		"\toutput.color = sample(tex, input.uv) * sin(input.position.x)\n",
		1,
		context.temp_allocator,
	)
	testing.expect_value(t, messages_for(source, .PC), "")
	testing.expect_value(t, messages_for(source, .VITA), "")
	testing.expect(t, strings.contains(messages_for(source, .PICA200), "MBS-E8"))
	testing.expect(t, strings.contains(messages_for(source, .PICA200), "MBS-E1"))
}

@(test)
a_helper_is_judged_by_the_stage_that_calls_it :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// `sin` in a helper only the fragment stage calls isn't a vertex problem (it is a 3DS fragment one, MBS-E2)
	helper := "wobble :: proc(x: f32) -> f32 {\n\treturn sin(x)\n}\n\nvertex_main"
	source, _ := strings.replace(no_carriage_returns(BASE), "\toutput.color = input.color * sin(input.position.x)\n", "", 1, context.temp_allocator)
	source, _ = strings.replace(source, "vertex_main", helper, 1, context.temp_allocator)
	source, _ = strings.replace(source, "return sample(tex, v.uv) * v.color", "return sample(tex, v.uv) * wobble(v.color.x)", 1, context.temp_allocator)
	messages := messages_for(source, .PICA200)
	testing.expect(t, strings.contains(messages, "MBS-E2"), messages)
	testing.expect(t, strings.contains(messages, "MBS-E1") == false, messages)
}

@(test)
a_varying_with_no_tag_gets_a_semantic_on_the_pc :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source := no_carriage_returns(#load("testdata/errors/e06_untagged_varying.mbs", string))
	parsed := parse_shader("test.mbs", source)
	defer destroy_parsed(parsed)
	check_subset(parsed)
	module := build_module(parsed, .PC)
	testing.expect_value(t, len(parsed.diagnostics), 0)
	text, problems := generate_hlsl(lower_module(module), context.temp_allocator)
	testing.expect_value(t, len(problems), 0)
	testing.expect(t, strings.contains(text, "normal : TEXCOORD3;") || strings.contains(text, "float3 normal : TEXCOORD3;"), text)
	expect_compiles(t, text)
}

@(test)
the_report_says_what_compiles_where :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	report, passed := check_report("mesh.mbs", mesh_source())
	testing.expect(t, passed)
	testing.expect(t, strings.contains(report, "pc    ok: compiles to HLSL"), report)
	testing.expect(t, strings.contains(report, "vita  ok"), report)
	testing.expect(t, strings.contains(report, "3ds   ok"), report)

	report, passed = check_report("e01.mbs", no_carriage_returns(BASE))
	testing.expect(t, passed == false)
	testing.expect(t, strings.contains(report, "3ds:\n"), report)
	testing.expect(t, strings.contains(report, "pc    ok"), report)
	testing.expect(t, strings.contains(report, "3ds   1 problem"), report)
	testing.expect(t, strings.contains(report, "all targets:") == false, report)
}

@(test)
a_mistake_in_every_target_is_listed_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	report, passed := check_report("e13.mbs", no_carriage_returns(#load("testdata/errors/e13_type_mismatch.mbs", string)))
	testing.expect(t, passed == false)
	testing.expect_value(t, strings.count(report, "error[MBS-E13]"), 1)
	testing.expect(t, strings.contains(report, "all targets:"), report)
	testing.expect(t, strings.contains(report, "pc    1 problem"), report)
	// the 3DS has the shared mistake and, in this shader, a matrix product its vertex unit can't do
	testing.expect(t, strings.contains(report, "3ds   2 problems"), report)
}
