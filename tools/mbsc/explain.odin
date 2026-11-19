package mbsc

import "core:strings"

// The error index is built into the program, so `mbsc --explain` works from any folder.
ERRORS_DOC :: #load("../../docs/shader_errors.md", string)

// normalize_code turns what the user typed into the form the index uses.
// "mbs-e12", "E12" and "MBS-E12" all give "MBS-E12". Warnings are the same with a W.
normalize_code :: proc(text: string, allocator := context.allocator) -> (code: string, ok: bool) {
	upper := strings.to_upper(strings.trim_space(text), context.temp_allocator)
	rest := upper
	if strings.has_prefix(rest, "MBS-") {
		rest = rest[len("MBS-"):]
	}
	if len(rest) < 2 || (rest[0] != 'E' && rest[0] != 'W') {
		return "", false
	}
	digits := rest[1:]
	for character in transmute([]u8)digits {
		if character < '0' || character > '9' {
			return "", false
		}
	}
	if digits[0] == '0' {
		return "", false
	}
	return strings.concatenate({"MBS-", rest}, allocator), true
}

// find_entry returns the text of one entry in the index, from its "## MBS-E<n>" heading up to the next "---".
find_entry :: proc(document: string, code: string, allocator := context.allocator) -> (entry: string, found: bool) {
	builder := strings.builder_make(allocator)
	heading := strings.concatenate({"## ", code}, context.temp_allocator)

	inside := false
	rest := document
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if inside == false {
			if line == heading {
				inside = true
				found = true
				strings.write_string(&builder, line)
				strings.write_string(&builder, "\n")
			}
			continue
		}
		if line == "---" || strings.has_prefix(line, "## MBS-") {
			break
		}
		strings.write_string(&builder, line)
		strings.write_string(&builder, "\n")
	}

	if found == false {
		strings.builder_destroy(&builder)
		return "", false
	}
	defer strings.builder_destroy(&builder)
	trimmed := strings.trim_right(strings.to_string(builder), "\n")
	return strings.concatenate({trimmed, "\n"}, allocator), true
}

// last_error_number is the highest MBS-E number in the index, used to say what the valid range is.
last_error_number :: proc(document: string) -> int {
	highest := 0
	rest := document
	for raw in strings.split_lines_iterator(&rest) {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(line, "## MBS-E") == false {
			continue
		}
		value := 0
		for character in transmute([]u8)line[len("## MBS-E"):] {
			if character < '0' || character > '9' {
				break
			}
			value = value * 10 + int(character - '0')
		}
		highest = max(highest, value)
	}
	return highest
}
