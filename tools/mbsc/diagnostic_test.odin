package mbsc

import "core:strings"
import "core:testing"

// Eleven empty lines, so the code is on line 12 and the line number takes two digits.
@(private = "file")
sin_source :: "\n\n\n\n\n\n\n\n\n\n\n        return 0.75 + 0.25 * sin(time * 8)\n"

@(test)
render_diagnostic_matches_the_documented_shape :: proc(t: ^testing.T) {
	column :: 30 // where `sin` starts on line 12
	diagnostic := Diagnostic {
		severity = .ERROR,
		code     = "MBS-E1",
		title    = "`sin` is not available in 3DS vertex shaders",
		file     = "hit_flash.mbs",
		source   = sin_source,
		label    = {line = 12, column = column, length = 3, text = "no sine instruction on this target"},
		notes    = {"building for `3ds`: the PICA200 vertex unit has no sin, cos, sqrt, pow or divide instruction"},
		helps    = {"use `sin_approx(x)`, a polynomial that works everywhere"},
	}

	text := render_diagnostic(diagnostic)
	defer delete(text)

	expected := strings.concatenate(
		{
			"error[MBS-E1]: `sin` is not available in 3DS vertex shaders\n",
			"  --> hit_flash.mbs:12:30\n",
			"   |\n",
			"12 |         return 0.75 + 0.25 * sin(time * 8)\n",
			"   |                              ^^^ no sine instruction on this target\n",
			"   |\n",
			"   = note: building for `3ds`: the PICA200 vertex unit has no sin, cos, sqrt, pow or divide instruction\n",
			"   = help: use `sin_approx(x)`, a polynomial that works everywhere\n",
			"   = more: docs/shader_errors.md#mbs-e1\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, text, expected)
}

@(test)
render_diagnostic_one_digit_line_and_warning :: proc(t: ^testing.T) {
	diagnostic := Diagnostic {
		severity = .WARNING,
		code     = "MBS-W1",
		title    = "constant outside the domain",
		file     = "a.mbs",
		source   = "x := sqrt(-1.0)\n",
		label    = {line = 1, column = 6, length = 10},
	}

	text := render_diagnostic(diagnostic)
	defer delete(text)

	expected := strings.concatenate(
		{
			"warning[MBS-W1]: constant outside the domain\n",
			" --> a.mbs:1:6\n",
			"  |\n",
			"1 | x := sqrt(-1.0)\n",
			"  |      ^^^^^^^^^^\n",
			"  |\n",
			"  = more: docs/shader_errors.md#mbs-w1\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, text, expected)
}

@(test)
render_diagnostic_expands_tabs_and_lines_up_notes :: proc(t: ^testing.T) {
	diagnostic := Diagnostic {
		severity = .ERROR,
		code     = "MBS-E2",
		title    = "fragment code outside the subset",
		file     = "t.mbs",
		source   = "\treturn pow(a, b)\r\n",
		label    = {line = 1, column = 9, length = 3, text = "not a combiner operation"},
		notes    = {"first line\nsecond line"},
	}

	text := render_diagnostic(diagnostic)
	defer delete(text)

	expected := strings.concatenate(
		{
			"error[MBS-E2]: fragment code outside the subset\n",
			" --> t.mbs:1:9\n",
			"  |\n",
			"1 |     return pow(a, b)\n",
			"  |            ^^^ not a combiner operation\n",
			"  |\n",
			"  = note: first line\n",
			"          second line\n",
			"  = more: docs/shader_errors.md#mbs-e2\n",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, text, expected)
}

@(test)
render_diagnostic_clamps_a_label_that_runs_past_the_line :: proc(t: ^testing.T) {
	diagnostic := Diagnostic {
		code   = "MBS-E13",
		title  = "type mismatch",
		file   = "t.mbs",
		source = "abc\n",
		label  = {line = 1, column = 2, length = 50},
	}

	text := render_diagnostic(diagnostic)
	defer delete(text)

	testing.expect(t, strings.contains(text, "  |  ^^\n"))
}

@(test)
get_source_line_finds_lines :: proc(t: ^testing.T) {
	source := "one\r\ntwo\nthree"
	testing.expect_value(t, get_source_line(source, 1), "one")
	testing.expect_value(t, get_source_line(source, 2), "two")
	testing.expect_value(t, get_source_line(source, 3), "three")
	testing.expect_value(t, get_source_line(source, 4), "")
}

@(test)
normalize_code_accepts_the_usual_spellings :: proc(t: ^testing.T) {
	for spelling in ([]string{"MBS-E12", "mbs-e12", "E12", "e12", " e12 "}) {
		code, ok := normalize_code(spelling)
		testing.expect(t, ok, spelling)
		testing.expect_value(t, code, "MBS-E12")
		delete(code)
	}

	code, ok := normalize_code("W2")
	testing.expect(t, ok)
	testing.expect_value(t, code, "MBS-W2")
	delete(code)

	for bad in ([]string{"", "MBS-", "12", "E", "E0", "E1x", "X5", "MBS-E-1"}) {
		_, bad_ok := normalize_code(bad)
		testing.expect(t, bad_ok == false, bad)
	}
}

@(test)
find_entry_returns_one_entry :: proc(t: ^testing.T) {
	document := "# Title\r\n\r\n## MBS-E1\r\n\r\n**One**\r\n\r\n---\r\n\r\n## MBS-E2\r\n\r\n**Two**\r\n\r\n---\r\n"

	entry, found := find_entry(document, "MBS-E2")
	defer delete(entry)
	testing.expect(t, found)
	testing.expect_value(t, entry, "## MBS-E2\n\n**Two**\n")

	_, missing := find_entry(document, "MBS-E3")
	testing.expect(t, missing == false)
}

@(test)
the_real_index_explains_every_error :: proc(t: ^testing.T) {
	last := last_error_number(ERRORS_DOC)
	testing.expect(t, last >= 21)

	for number in 1 ..= last {
		code := strings.concatenate({"MBS-E", number_text(number)}, context.temp_allocator)
		entry, found := find_entry(ERRORS_DOC, code)
		testing.expectf(t, found, "%s has no entry in docs/shader_errors.md", code)
		if found {
			testing.expectf(t, strings.contains(entry, "**"), "%s has no title", code)
			delete(entry)
		}
	}
}

@(private = "file")
number_text :: proc(number: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_int(&builder, number)
	return strings.to_string(builder)
}
