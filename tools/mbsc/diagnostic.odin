package mbsc

import "core:strings"

// A compiler message in the style of rustc: what is wrong, where, why, and a fix.
// The rules for writing one are in docs/shader_errors.md.

Severity :: enum {
	ERROR,
	WARNING,
}

// The piece of code the message points at. Line and column start at 1; the column counts bytes.
Label :: struct {
	line:   int,
	column: int,
	length: int,
	text:   string,
}

Diagnostic :: struct {
	severity: Severity,
	code:     string, // "MBS-E1"
	title:    string,
	file:     string,
	source:   string, // the whole file, so the line can be shown
	label:    Label,
	notes:    []string, // the reason; a note may span lines with "\n"
	helps:    []string, // a fix the author can apply; the same applies
}

TAB_WIDTH :: 4

// render_diagnostic returns the message as text, ready to print. The caller frees it.
render_diagnostic :: proc(d: Diagnostic, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)

	line_text := get_source_line(d.source, d.label.line)
	number := digit_count(d.label.line)
	gutter := number + 1 // the width of the number, plus the space before the bar

	// error[MBS-E1]: title
	strings.write_string(&builder, severity_word(d.severity))
	strings.write_string(&builder, "[")
	strings.write_string(&builder, d.code)
	strings.write_string(&builder, "]: ")
	strings.write_string(&builder, d.title)
	strings.write_string(&builder, "\n")

	//   --> file:line:column
	write_spaces(&builder, number)
	strings.write_string(&builder, "--> ")
	strings.write_string(&builder, d.file)
	strings.write_string(&builder, ":")
	write_int(&builder, d.label.line)
	strings.write_string(&builder, ":")
	write_int(&builder, d.label.column)
	strings.write_string(&builder, "\n")

	write_spaces(&builder, gutter)
	strings.write_string(&builder, "|\n")

	// 12 |     the line of code
	write_int(&builder, d.label.line)
	strings.write_string(&builder, " | ")
	write_expanded(&builder, line_text)
	strings.write_string(&builder, "\n")

	//    |      ^^^ what this piece of code is doing wrong
	write_spaces(&builder, gutter)
	strings.write_string(&builder, "| ")
	write_spaces(&builder, expanded_width(line_text, d.label.column - 1))
	carets := max(d.label.length, 1)
	if d.label.column - 1 + carets > len(line_text) {
		carets = max(len(line_text) - (d.label.column - 1), 1)
	}
	for _ in 0 ..< carets {
		strings.write_string(&builder, "^")
	}
	if len(d.label.text) > 0 {
		strings.write_string(&builder, " ")
		strings.write_string(&builder, d.label.text)
	}
	strings.write_string(&builder, "\n")

	write_spaces(&builder, gutter)
	strings.write_string(&builder, "|\n")

	for note in d.notes {
		write_note(&builder, gutter, "= note: ", note)
	}
	for help in d.helps {
		write_note(&builder, gutter, "= help: ", help)
	}
	write_note(&builder, gutter, "= more: ", more_link(d.code, context.temp_allocator))

	return strings.to_string(builder)
}

// more_link is the line every message ends with, e.g. "docs/shader_errors.md#mbs-e1".
more_link :: proc(code: string, allocator := context.allocator) -> string {
	return strings.concatenate({"docs/shader_errors.md#", strings.to_lower(code, context.temp_allocator)}, allocator)
}

// get_source_line returns line number `line` (counting from 1) without its line ending.
// A line past the end of the file is an empty string.
get_source_line :: proc(source: string, line: int) -> string {
	rest := source
	current := 1
	for current < line {
		newline := strings.index_byte(rest, '\n')
		if newline < 0 {
			return ""
		}
		rest = rest[newline + 1:]
		current += 1
	}
	newline := strings.index_byte(rest, '\n')
	if newline >= 0 {
		rest = rest[:newline]
	}
	return strings.trim_right(rest, "\r")
}

@(private = "file")
severity_word :: proc(severity: Severity) -> string {
	switch severity {
	case .ERROR:
		return "error"
	case .WARNING:
		return "warning"
	}
	return "error"
}

@(private = "file")
digit_count :: proc(value: int) -> int {
	count := 1
	for rest := value / 10; rest > 0; rest /= 10 {
		count += 1
	}
	return count
}

@(private = "file")
write_spaces :: proc(builder: ^strings.Builder, count: int) {
	for _ in 0 ..< count {
		strings.write_string(builder, " ")
	}
}

@(private = "file")
write_int :: proc(builder: ^strings.Builder, value: int) {
	strings.write_int(builder, value)
}

// write_expanded writes the line with each tab turned into spaces, so the carets line up.
@(private = "file")
write_expanded :: proc(builder: ^strings.Builder, line: string) {
	for character in transmute([]u8)line {
		if character == '\t' {
			write_spaces(builder, TAB_WIDTH)
		} else {
			strings.write_byte(builder, character)
		}
	}
}

// expanded_width is how many columns the first `bytes` bytes of the line take once tabs are expanded.
@(private = "file")
expanded_width :: proc(line: string, bytes: int) -> int {
	width := 0
	for character, index in transmute([]u8)line {
		if index >= bytes {
			break
		}
		width += TAB_WIDTH if character == '\t' else 1
	}
	return width
}

// write_note writes "   = note: text"; a second line of the text lines up under the first.
@(private = "file")
write_note :: proc(builder: ^strings.Builder, gutter: int, prefix: string, text: string) {
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		write_spaces(builder, gutter)
		if first {
			strings.write_string(builder, prefix)
			first = false
		} else {
			write_spaces(builder, len(prefix))
		}
		strings.write_string(builder, line)
		strings.write_string(builder, "\n")
	}
}
