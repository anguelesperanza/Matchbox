package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"

// A .mbs file is Odin without the `package` line. Odin's parser needs one, so mbsc puts it in front of the
// text on the same line. Nothing moves down, and a position on line 1 only needs the length taken off its column.
PACKAGE_PREFIX :: "package shader;"

// Parsed is a shader read by Odin's parser, plus every message found so far. Everything in it, the tree and the
// message text, lives in one arena, so destroy_parsed frees it all at once.
Parsed :: struct {
	name:        string, // the file name, for messages
	source:      string, // the text as the author wrote it, without the package prefix
	file:        ^ast.File,
	diagnostics: [dynamic]Diagnostic,
	has_syntax_errors: bool,
	arena:       virtual.Arena,
}

// parse_shader reads a shader. It never fails outright: problems come back in `diagnostics`, and the tree is
// only trustworthy when `has_syntax_errors` is false. The caller calls destroy_parsed.
parse_shader :: proc(name: string, source: string) -> ^Parsed {
	parsed := new(Parsed)
	parsed.name = name
	parsed.source = source
	_ = virtual.arena_init_growing(&parsed.arena)

	context.allocator = virtual.arena_allocator(&parsed.arena)
	context.user_ptr = parsed
	parsed.diagnostics = make([dynamic]Diagnostic)

	prefixed := strings.concatenate({PACKAGE_PREFIX, source})
	parsed.file = new(ast.File)
	parsed.file.src = prefixed
	parsed.file.fullpath = name

	odin_parser := parser.default_parser()
	odin_parser.err = syntax_error_handler
	odin_parser.warn = ignore_warning
	parser.parse_file(&odin_parser, parsed.file)

	if parsed.file.syntax_error_count > 0 {
		parsed.has_syntax_errors = true
	}
	return parsed
}

destroy_parsed :: proc(parsed: ^Parsed) {
	virtual.arena_destroy(&parsed.arena)
	free(parsed)
}

@(private = "file")
ignore_warning :: proc(pos: tokenizer.Pos, format: string, args: ..any) {}

@(private = "file")
syntax_error_handler :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	parsed := cast(^Parsed)context.user_ptr
	line, column := shader_position(pos)
	message := fmt.aprintf(format, ..args)

	// Odin sometimes reports the same problem twice in a row.
	if count := len(parsed.diagnostics); count > 0 {
		previous := parsed.diagnostics[count - 1]
		if previous.label.line == line && previous.label.column == column && previous.title == message {
			return
		}
	}

	parsed.has_syntax_errors = true
	append(
		&parsed.diagnostics,
		Diagnostic {
			severity = .ERROR,
			code = "MBS-E22",
			title = message,
			file = parsed.name,
			source = parsed.source,
			label = {line = line, column = column, length = token_length_at(parsed.source, line, column), text = "Odin's parser stopped here"},
			notes = one_line("mbsc reads a shader with Odin's own parser, and this is the message the parser gives"),
		},
	)
}

// shader_position turns a position in the prefixed text into a line and column in the author's text.
shader_position :: proc(pos: tokenizer.Pos) -> (line: int, column: int) {
	line = pos.line
	column = pos.column
	if line == 1 {
		column = max(column - len(PACKAGE_PREFIX), 1)
	}
	return
}

// token_length_at guesses how wide the token at a position is, so the carets cover it.
@(private = "file")
token_length_at :: proc(source: string, line: int, column: int) -> int {
	text := get_source_line(source, line)
	start := column - 1
	if start < 0 || start >= len(text) {
		return 1
	}
	is_word :: proc(character: u8) -> bool {
		return (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '_'
	}
	if is_word(text[start]) == false {
		return 1
	}
	end := start
	for end < len(text) && is_word(text[end]) {
		end += 1
	}
	return end - start
}

// one_line makes the one-item list a Diagnostic's notes and helps are. An empty text gives no list.
one_line :: proc(text: string) -> []string {
	if len(text) == 0 {
		return nil
	}
	list := make([]string, 1)
	list[0] = text
	return list
}

// add_diagnostic records one message against a position in the shader. `length` is how many characters the
// carets cover. An empty note or help is left out.
add_diagnostic :: proc(parsed: ^Parsed, code, title: string, pos: tokenizer.Pos, length: int, label, note, help: string) {
	line, column := shader_position(pos)
	append(
		&parsed.diagnostics,
		Diagnostic {
			severity = .ERROR,
			code = code,
			title = title,
			file = parsed.name,
			source = parsed.source,
			label = {line = line, column = column, length = length, text = label},
			notes = one_line(note),
			helps = one_line(help),
		},
	)
}
