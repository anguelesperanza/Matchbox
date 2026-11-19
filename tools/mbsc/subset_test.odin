package mbsc

import "core:strings"
import "core:testing"

@(private = "file")
MESH :: #load("testdata/mesh.mbs", string)

@(private = "file")
check_source :: proc(source: string) -> ^Parsed {
	parsed := parse_shader("test.mbs", source)
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
	}
	return parsed
}

@(private = "file")
Case :: struct {
	name:   string,
	source: string,
	code:   string,
	line:   int,
	column: int,
	title:  string, // a piece of the title
}

@(test)
subset_rejects_what_the_shader_language_leaves_out :: proc(t: ^testing.T) {
	cases := []Case {
		{"import", "import \"core:math\"\n", "MBS-E16", 1, 1, "`import`"},
		{"defer", "f :: proc() {\n\tdefer x()\n}\n", "MBS-E16", 2, 2, "`defer`"},
		{"switch", "f :: proc(x: f32) {\n\tswitch x {\n\t}\n}\n", "MBS-E16", 2, 2, "`switch`"},
		{"while loop", "f :: proc() {\n\tfor true {\n\t}\n}\n", "MBS-E16", 2, 2, "form of `for`"},
		{"c style loop", "f :: proc() {\n\tfor i := 0; i < 4; i += 1 {\n\t}\n}\n", "MBS-E16", 2, 2, "form of `for`"},
		{"loop over an array", "f :: proc(a: [4]f32) {\n\tfor v in a {\n\t}\n}\n", "MBS-E16", 2, 2, "form of `for`"},
		{"break", "f :: proc() {\n\tfor i in 0..<4 {\n\t\tbreak\n\t}\n}\n", "MBS-E16", 3, 3, "`break`"},
		{"pointer", "P :: struct {\n\tp: ^f32,\n}\n", "MBS-E16", 2, 5, "pointers"},
		{"string type", "P :: struct {\n\tname: string,\n}\n", "MBS-E16", 2, 8, "`string`"},
		{"string literal", "s :: \"hi\"\n", "MBS-E16", 1, 6, "strings"},
		{"slice type", "P :: struct {\n\tv: []f32,\n}\n", "MBS-E16", 2, 5, "slices"},
		{"matrix element", "f :: proc(m: matrix[4, 4]f32) -> f32 {\n\treturn m[0, 1]\n}\n", "MBS-E16", 2, 9, "matrix elements"},
		{"dynamic array","P :: struct {\n\tv: [dynamic]f32,\n}\n", "MBS-E16", 2, 5, "dynamic arrays"},
		{"map", "P :: struct {\n\tv: map[int]f32,\n}\n", "MBS-E16", 2, 5, "maps"},
		{"enum", "E :: enum {A, B}\n", "MBS-E16", 1, 6, "`enum`"},
		{"union", "U :: union {f32, bool}\n", "MBS-E16", 1, 6, "`union`"},
		{"modulo", "f :: proc(a: f32) -> f32 {\n\treturn a % 2.0\n}\n", "MBS-E16", 2, 11, "`%`"},
		{"shift", "f :: proc(a: i32) -> i32 {\n\treturn a << 2\n}\n", "MBS-E16", 2, 11, "`<<`"},
		{"bit and", "f :: proc(a: i32) -> i32 {\n\treturn a & 2\n}\n", "MBS-E16", 2, 11, "`&`"},
		{"ternary", "f :: proc(a: f32) -> f32 {\n\treturn a if true else 1.0\n}\n", "MBS-E16", 2, 9, "`a if cond else b`"},
		{"cast", "f :: proc(a: i32) -> f32 {\n\treturn cast(f32)a\n}\n", "MBS-E16", 2, 9, "`cast`"},
		{"context", "f :: proc() {\n\tx := context\n}\n", "MBS-E16", 2, 7, "`context`"},
		{"new", "f :: proc() {\n\tx := new(f32)\n}\n", "MBS-E16", 2, 7, "`new`"},
		{"procedure inside a procedure", "f :: proc() {\n\tg := proc() {}\n}\n", "MBS-E16", 2, 7, "top level"},
		{"two results", "f :: proc() -> (f32, f32) {\n}\n", "MBS-E16", 1, 6, "only one value"},
		{"generic procedure", "f :: proc(x: $T) -> T {\n\treturn x\n}\n", "MBS-E16", 1, 6, "generic"},
		{"two names", "f :: proc() {\n\ta, b := 1.0, 2.0\n}\n", "MBS-E16", 2, 5, "only one name"},
		{"swap", "f :: proc() {\n\ta, b = b, a\n}\n", "MBS-E16", 2, 2, "several values"},
		{"using", "f :: proc() {\n\tusing x\n}\n", "MBS-E16", 2, 2, "`using`"},
		{"label", "f :: proc() {\n\touter: for i in 0..<4 {\n\t}\n}\n", "MBS-E16", 2, 2, "labels"},
		{"directive", "f :: proc() {\n\t#assert(true)\n}\n", "MBS-E16", 2, 2, "`#`"},
		{"address of", "f :: proc(x: f32) {\n\tp := &x\n}\n", "MBS-E16", 2, 7, "pointers"},
	}

	for entry in cases {
		parsed := check_source(entry.source)
		defer destroy_parsed(parsed)

		if testing.expectf(t, len(parsed.diagnostics) >= 1, "%s: no error was reported", entry.name) == false {
			continue
		}
		first := parsed.diagnostics[0]
		testing.expectf(t, first.code == entry.code, "%s: code %s, wanted %s", entry.name, first.code, entry.code)
		testing.expectf(
			t,
			first.label.line == entry.line && first.label.column == entry.column,
			"%s: at %d:%d, wanted %d:%d",
			entry.name,
			first.label.line,
			first.label.column,
			entry.line,
			entry.column,
		)
		testing.expectf(t, strings.contains(first.title, entry.title), "%s: title '%s' lacks '%s'", entry.name, first.title, entry.title)
	}
}

@(test)
subset_accepts_the_allowed_part_of_odin :: proc(t: ^testing.T) {
	source := `Thing :: struct {
	a: [4]f32 ` + "`attr:\"position\"`" + `,
	b: matrix[4, 4]f32,
}

@(uniform = .FRAME) frame: struct { m: matrix[4, 4]f32 }

LIMIT :: 4

helper :: proc(x: f32, v: [4]f32) -> f32 {
	total := 0.0
	for i in 0..<LIMIT {
		total += x * f32(i)
	}
	for i in 0..=3 {
		total -= 1.0
	}
	if x > 1.0 && v.x < 2.0 || !(x == 0.0) {
		total = -total / 2.0
	} else if x >= 3.0 {
		total *= 2.0
	}
	when TARGET == .PICA200 {
		total = 1.0
	} else {
		total = total + v.zyx.x + v.rgba.a
	}
	return total
}
`
	parsed := check_source(source)
	defer destroy_parsed(parsed)

	for diagnostic in parsed.diagnostics {
		testing.expectf(t, false, "unexpected %s: %s (%d:%d)", diagnostic.code, diagnostic.title, diagnostic.label.line, diagnostic.label.column)
	}
}

@(test)
subset_accepts_the_spec_mesh_shader :: proc(t: ^testing.T) {
	parsed := check_source(MESH)
	defer destroy_parsed(parsed)

	for diagnostic in parsed.diagnostics {
		testing.expectf(t, false, "unexpected %s: %s (%d:%d)", diagnostic.code, diagnostic.title, diagnostic.label.line, diagnostic.label.column)
	}
}

@(test)
every_problem_in_a_file_is_reported :: proc(t: ^testing.T) {
	parsed := check_source("import \"core:math\"\n\nP :: struct {\n\tp: ^f32,\n}\n\nf :: proc() {\n\tdefer x()\n}\n")
	defer destroy_parsed(parsed)

	testing.expect_value(t, len(parsed.diagnostics), 3)
}

@(test)
a_syntax_error_is_reported_as_e22_and_stops_the_subset_check :: proc(t: ^testing.T) {
	// The `^f32` would be an E16, but the file doesn't parse, so only the syntax error is reported.
	parsed := check_source("P :: struct {\n\tp: ^f32,\n\nf :: proc() {\n}\n")
	defer destroy_parsed(parsed)

	testing.expect(t, parsed.has_syntax_errors)
	testing.expect(t, len(parsed.diagnostics) >= 1)
	for diagnostic in parsed.diagnostics {
		testing.expect_value(t, diagnostic.code, "MBS-E22")
	}
}

@(test)
a_position_on_line_one_is_not_moved_by_the_package_prefix :: proc(t: ^testing.T) {
	parsed := check_source("x := \"text\"\n")
	defer destroy_parsed(parsed)

	if testing.expect(t, len(parsed.diagnostics) >= 1) {
		testing.expect_value(t, parsed.diagnostics[0].label.line, 1)
		testing.expect_value(t, parsed.diagnostics[0].label.column, 6)
	}
}

@(test)
messages_render_against_the_authors_text :: proc(t: ^testing.T) {
	parsed := check_source("\tx :: 5\n\tdefer y()\n")
	defer destroy_parsed(parsed)

	if testing.expect(t, len(parsed.diagnostics) >= 1) {
		text := render_diagnostic(parsed.diagnostics[0])
		defer delete(text)
		testing.expect(t, strings.contains(text, "\n2 |     defer y()\n"), text)
	}
}
