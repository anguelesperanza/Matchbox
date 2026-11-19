package mbsc

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:testing"

// One small shader per error, in testdata/errors, each broken in exactly one way. The messages mbsc prints for
// them are kept next to them (`.txt`), so a change to a message or to where it points shows up as a failing test.
//
// To change a message on purpose: run
//     mbsc tools/mbsc/testdata/errors/<name>.mbs -target:<the target in the table below> 2> tools/mbsc/testdata/errors/<name>.txt
// from the folder that holds the file, so the file name in the message stays what the test uses.

@(private = "file")
Golden :: struct {
	name:   string, // the shader's file name, without the extension; it starts with the error's number
	code:   string, // the one error code the shader should give
	target: Target, // the target it is built for; some errors exist on one target only
	source: string,
	golden: string,
}

@(private = "file")
golden_cases := [?]Golden {
	{"e01_vertex_builtin", "MBS-E1", .PICA200, #load("testdata/errors/e01_vertex_builtin.mbs", string), #load("testdata/errors/e01_vertex_builtin.txt", string)},
	{"e04_too_many_uniforms", "MBS-E4", .PICA200, #load("testdata/errors/e04_too_many_uniforms.mbs", string), #load("testdata/errors/e04_too_many_uniforms.txt", string)},
	{"e06_untagged_varying", "MBS-E6", .PICA200, #load("testdata/errors/e06_untagged_varying.mbs", string), #load("testdata/errors/e06_untagged_varying.txt", string)},
	{"e07_loop_bound", "MBS-E7", .PC, #load("testdata/errors/e07_loop_bound.mbs", string), #load("testdata/errors/e07_loop_bound.txt", string)},
	{"e08_sample_in_vertex", "MBS-E8", .PICA200, #load("testdata/errors/e08_sample_in_vertex.mbs", string), #load("testdata/errors/e08_sample_in_vertex.txt", string)},
	{"e09_integer_arithmetic", "MBS-E9", .PICA200, #load("testdata/errors/e09_integer_arithmetic.mbs", string), #load("testdata/errors/e09_integer_arithmetic.txt", string)},
	{"e10_dynamic_index", "MBS-E10", .PICA200, #load("testdata/errors/e10_dynamic_index.mbs", string), #load("testdata/errors/e10_dynamic_index.txt", string)},
	{"e11_condition", "MBS-E11", .PICA200, #load("testdata/errors/e11_condition.mbs", string), #load("testdata/errors/e11_condition.txt", string)},
	{"e12_discard", "MBS-E12", .PICA200, #load("testdata/errors/e12_discard.mbs", string), #load("testdata/errors/e12_discard.txt", string)},
	{"e13_type_mismatch", "MBS-E13", .PC, #load("testdata/errors/e13_type_mismatch.mbs", string), #load("testdata/errors/e13_type_mismatch.txt", string)},
	{"e14_unknown_name", "MBS-E14", .PC, #load("testdata/errors/e14_unknown_name.mbs", string), #load("testdata/errors/e14_unknown_name.txt", string)},
	{"e15_no_fragment_main", "MBS-E15", .PC, #load("testdata/errors/e15_no_fragment_main.mbs", string), #load("testdata/errors/e15_no_fragment_main.txt", string)},
	{"e16_outside_the_subset", "MBS-E16", .PC, #load("testdata/errors/e16_outside_the_subset.mbs", string), #load("testdata/errors/e16_outside_the_subset.txt", string)},
	{"e17_recursion", "MBS-E17", .PC, #load("testdata/errors/e17_recursion.mbs", string), #load("testdata/errors/e17_recursion.txt", string)},
	{"e18_engine_field", "MBS-E18", .PC, #load("testdata/errors/e18_engine_field.mbs", string), #load("testdata/errors/e18_engine_field.txt", string)},
	{"e19_four_textures", "MBS-E19", .PICA200, #load("testdata/errors/e19_four_textures.mbs", string), #load("testdata/errors/e19_four_textures.txt", string)},
	{"e20_texcoord", "MBS-E20", .PICA200, #load("testdata/errors/e20_texcoord.mbs", string), #load("testdata/errors/e20_texcoord.txt", string)},
	{"e22_syntax_error", "MBS-E22", .PC, #load("testdata/errors/e22_syntax_error.mbs", string), #load("testdata/errors/e22_syntax_error.txt", string)},
	{"e23_when_condition", "MBS-E23", .PC, #load("testdata/errors/e23_when_condition.mbs", string), #load("testdata/errors/e23_when_condition.txt", string)},
	{"e24_unknown_attribute", "MBS-E24", .PC, #load("testdata/errors/e24_unknown_attribute.mbs", string), #load("testdata/errors/e24_unknown_attribute.txt", string)},
	{"e25_declared_twice", "MBS-E25", .PC, #load("testdata/errors/e25_declared_twice.mbs", string), #load("testdata/errors/e25_declared_twice.txt", string)},
	{"e26_fragment_only_in_vertex", "MBS-E26", .PC, #load("testdata/errors/e26_fragment_only_in_vertex.mbs", string), #load("testdata/errors/e26_fragment_only_in_vertex.txt", string)},
	{"e27_assign_read_only", "MBS-E27", .PC, #load("testdata/errors/e27_assign_read_only.mbs", string), #load("testdata/errors/e27_assign_read_only.txt", string)},
	{"e28_array_result", "MBS-E28", .PC, #load("testdata/errors/e28_array_result.mbs", string), #load("testdata/errors/e28_array_result.txt", string)},
}

@(private = "file")
no_carriage_returns :: proc(text: string) -> string {
	result, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	return result
}

@(test)
each_error_has_a_shader_that_gives_it_and_nothing_else :: proc(t: ^testing.T) {
	for entry in golden_cases {
		defer free_all(context.temp_allocator)

		parsed := parse_shader(fmt.tprintf("%s.mbs", entry.name), no_carriage_returns(entry.source))
		defer destroy_parsed(parsed)
		if parsed.has_syntax_errors == false {
			check_subset(parsed)
			if len(parsed.diagnostics) == 0 {
				build_module(parsed, entry.target)
			}
		}

		testing.expectf(t, len(parsed.diagnostics) > 0, "%s: gave no error", entry.name)
		for diagnostic in parsed.diagnostics {
			testing.expectf(t, diagnostic.code == entry.code, "%s: expected only %s, also got %s: %s", entry.name, entry.code, diagnostic.code, diagnostic.title)
		}
		testing.expectf(t, len(parsed.diagnostics) == 1, "%s: expected one message, got %d", entry.name, len(parsed.diagnostics))

		got := render_errors(parsed, fmt.tprintf("%s.mbs", entry.name))
		defer delete(got)
		want := no_carriage_returns(entry.golden)
		if got != want {
			testing.expectf(t, false, "%s: the messages differ from testdata/errors/%s.txt", entry.name, entry.name)
			fmt.eprintfln("--- got ---\n%s--- want ---\n%s", got, want)
		}
	}
}

@(test)
every_golden_shader_is_a_different_error :: proc(t: ^testing.T) {
	seen := make(map[string]bool, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for entry in golden_cases {
		testing.expectf(t, seen[entry.code] == false, "%s has two golden shaders", entry.code)
		seen[entry.code] = true
		number, _ := strconv.parse_int(entry.code[5:])
		testing.expectf(t, strings.has_prefix(entry.name, fmt.tprintf("e%02d_", number)), "%s: the file name should start with e%02d_", entry.name, number)
	}
}

@(test)
every_implemented_error_is_in_the_golden_set_or_waits_for_a_later_step :: proc(t: ^testing.T) {
	// These need a backend to decide (S5 and S6: the fragment plan, combiner stages, registers); no golden file yet.
	waiting := [?]string{"MBS-E2", "MBS-E3", "MBS-E5", "MBS-E21"}
	defer free_all(context.temp_allocator)

	for number in 1 ..= 28 {
		code := fmt.tprintf("MBS-E%d", number)
		covered := false
		for entry in golden_cases {
			covered ||= entry.code == code
		}
		for later in waiting {
			covered ||= later == code
		}
		testing.expectf(t, covered, "%s is neither in the golden set nor listed as waiting for a later step", code)
	}
}
