package mbsc

import "core:strings"
import "core:testing"

// A cycle of calls is reported once, however many ways the walk reaches it.

@(private = "file")
SHADER_HEAD :: `Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
}

Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	return v.position
}
`

@(private = "file")
VERTEX_START :: "\nvertex_main :: proc(input: Vertex_In) -> Varying {\n\toutput: Varying\n\t"

@(private = "file")
VERTEX_END :: "\n\treturn output\n}\n"

@(private = "file")
SELF :: "fade :: proc(x: f32) -> f32 {\n\treturn fade(x - 1.0)\n}\n"

@(private = "file")
PAIR :: "ping :: proc(x: f32) -> f32 {\n\treturn pong(x)\n}\npong :: proc(x: f32) -> f32 {\n\treturn ping(x)\n}\n"

@(private = "file")
TWO :: "a :: proc(x: f32) -> f32 {\n\treturn a(x)\n}\nb :: proc(x: f32) -> f32 {\n\treturn b(x)\n}\n"

@(private = "file")
INTO :: "a :: proc(x: f32) -> f32 {\n\treturn a(x)\n}\nb :: proc(x: f32) -> f32 {\n\treturn a(x)\n}\n"

// count_cycles checks a shader made of `helpers` and a vertex stage that runs `vertex_statement`.
@(private = "file")
count_cycles :: proc(helpers: string, vertex_statement: string) -> int {
	defer free_all(context.temp_allocator)

	source := strings.concatenate({SHADER_HEAD, helpers, VERTEX_START, vertex_statement, VERTEX_END}, context.temp_allocator)

	parsed := parse_shader("test.mbs", source)
	defer destroy_parsed(parsed)
	check_subset(parsed)
	build_module(parsed, .PC)

	total := 0
	for diagnostic in parsed.diagnostics {
		if diagnostic.code == "MBS-E17" {
			total += 1
		}
	}
	return total
}

@(test)
a_cycle_is_reported_once_however_it_is_reached :: proc(t: ^testing.T) {
	// self-recursion, reached from the vertex stage, and never called
	testing.expect_value(t, count_cycles(SELF, "x := fade(1.0)"), 1)
	testing.expect_value(t, count_cycles(SELF, "output.position.x = 1.0"), 1)
	// a pair, reached from the vertex stage
	testing.expect_value(t, count_cycles(PAIR, "x := ping(1.0)"), 1)
	// two separate cycles are two messages
	testing.expect_value(t, count_cycles(TWO, "x := a(1.0) + b(1.0)"), 2)
	// a procedure that calls into a cycle without being part of it adds nothing
	testing.expect_value(t, count_cycles(INTO, "x := b(1.0)"), 1)
}
