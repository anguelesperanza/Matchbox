package mbsc

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

/*
	mbsc: the Matchbox Shader Compiler.

	mbsc <file.mbs> -target:pc|vita|3ds [--check] [--dump-ir] [--emit-hlsl | --emit-cg | --emit-pica | --emit-reflection] [-o:<file>]
	mbsc --explain MBS-E<n>

	The language is in docs/shader_language.md and the errors in docs/shader_errors.md.
*/

// The targets a shader can build for. The names match `TARGET` in the language (part 1, section 6).
Target :: enum {
	PC,
	VITA,
	PICA200,
}

USAGE :: `mbsc: the Matchbox Shader Compiler

usage:
  mbsc <file.mbs> -target:pc|vita|3ds [--check] [--dump-ir] [--emit-hlsl | --emit-cg | --emit-pica | --emit-reflection] [-o:<file>]
  mbsc --explain MBS-E<n>

options:
  -target:<name>     pc, vita or 3ds
  --check            check the shader and report errors; write nothing. With no -target, checks pc, vita
                     and 3ds and reports what compiles where
  --dump-ir          check the shader, then print its intermediate form
  --emit-hlsl        check the shader, then print it as HLSL (only for -target:pc)
  --emit-cg          check the shader, then print it as Cg: a vertex and a fragment program (only for -target:vita).
                     -o:<name> writes <name>_v.cg and <name>_f.cg
  --emit-pica        check the shader, then print its vertex program as PICA200 assembly and its
                     fragment plan as a TexEnv table (only for -target:3ds).
                     -o:<name> writes <name>.v.pica and <name>.tev (the fragment plan)
  --emit-reflection  check the shader, then print its reflection file
  -o:<file>          write the HLSL or the reflection to this file instead of printing it
  --explain <code>   explain an error, for example MBS-E12
  --help             show this text
`

// exit codes: 0 ok, 1 the shader has errors (or an unknown code was asked for), 2 the tool was used wrongly
EXIT_OK :: 0
EXIT_ERRORS :: 1
EXIT_USAGE :: 2

main :: proc() {
	os.exit(run(os.args[1:]))
}

Options :: struct {
	file:     string,
	target:   Target,
	has_target: bool,
	check:    bool,
	dump_ir:  bool,
	emit_hlsl: bool,
	emit_cg: bool,
	emit_pica: bool,
	emit_reflection: bool,
	output:   string,
	explain:  string,
	help:     bool,
}

run :: proc(args: []string) -> int {
	options, ok := parse_arguments(args)
	if ok == false {
		return EXIT_USAGE
	}

	if options.help {
		fmt.print(USAGE)
		return EXIT_OK
	}
	if len(options.explain) > 0 {
		return explain(options.explain)
	}
	if len(options.file) == 0 {
		fmt.eprint(USAGE)
		return EXIT_USAGE
	}
	if options.has_target == false && options.check == false {
		fmt.eprintln("mbsc: no target given; add -target:pc, -target:vita or -target:3ds (--check alone checks all three)")
		return EXIT_USAGE
	}

	data, read_error := os.read_entire_file_from_path(options.file, context.allocator)
	if read_error != nil {
		fmt.eprintfln("mbsc: can't read %s: %v", options.file, read_error)
		return EXIT_USAGE
	}
	defer delete(data)

	if options.has_target == false {
		if options.dump_ir || options.emit_hlsl || options.emit_cg || options.emit_pica || options.emit_reflection || len(options.output) > 0 {
			fmt.eprintln("mbsc: --dump-ir, --emit-hlsl, --emit-cg, --emit-pica, --emit-reflection and -o: need a -target:")
			return EXIT_USAGE
		}
		report, passed := check_report(options.file, string(data))
		defer delete(report)
		if passed {
			fmt.print(report)
			return EXIT_OK
		}
		fmt.fprint(os.stderr, report)
		return EXIT_ERRORS
	}
	if options.emit_hlsl && options.target != .PC {
		fmt.eprintln("mbsc: --emit-hlsl is for -target:pc; the Vita takes Cg (--emit-cg) and the 3DS takes PICA assembly")
		return EXIT_USAGE
	}
	if options.emit_cg && options.target != .VITA {
		fmt.eprintln("mbsc: --emit-cg is for -target:vita; the PC takes HLSL (--emit-hlsl) and the 3DS takes PICA assembly")
		return EXIT_USAGE
	}
	if options.emit_pica && options.target != .PICA200 {
		fmt.eprintln("mbsc: --emit-pica is for -target:3ds; the PC takes HLSL (--emit-hlsl) and the Vita takes Cg (--emit-cg)")
		return EXIT_USAGE
	}
	emits := int(options.emit_hlsl) + int(options.emit_cg) + int(options.emit_pica) + int(options.emit_reflection)
	if emits > 1 {
		fmt.eprintln("mbsc: write the HLSL, the Cg, the PICA assembly or the reflection one at a time")
		return EXIT_USAGE
	}
	if len(options.output) > 0 && emits == 0 {
		fmt.eprintln("mbsc: -o: is for --emit-hlsl, --emit-cg, --emit-pica and --emit-reflection; there is nothing else to write yet")
		return EXIT_USAGE
	}
	return check_shader(options.file, string(data), options.target, options.dump_ir, options.emit_hlsl, options.output, options.emit_reflection, options.emit_cg, options.emit_pica)
}

// check_shader reads the shader and prints what is wrong with it. It checks that the file parses, stays inside
// the subset, declares its structs, uniforms, textures and entry points correctly, and that the insides of
// procedures type-check. A shader that passes is lowered to the intermediate form, which --dump-ir prints.
check_shader :: proc(file: string, source: string, target: Target, dump := false, emit_hlsl := false, output := "", emit_reflection := false, emit_cg := false, emit_pica := false) -> int {
	parsed := parse_shader(file, source)
	defer destroy_parsed(parsed)

	module: ^Module
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
		if len(parsed.diagnostics) == 0 {
			module = build_module(parsed, target)
		}
	}

	if len(parsed.diagnostics) == 0 {
		ir := lower_module(module)
		if dump {
			text := dump_ir(ir)
			defer delete(text)
			fmt.print(text)
			return EXIT_OK
		}
		if emit_hlsl {
			text, problems := generate_hlsl(ir)
			defer delete(text)
			defer delete(problems)
			if len(problems) > 0 {
				for problem in problems {
					fmt.eprintfln("mbsc: %s: the HLSL backend can't write this shader yet: %s", file, problem)
				}
				return EXIT_ERRORS
			}
			return write_output(text, output)
		}
		if emit_cg {
			programs, problems := generate_cg(ir)
			defer delete(programs.vertex)
			defer delete(programs.fragment)
			defer delete(problems)
			if len(problems) > 0 {
				for problem in problems {
					fmt.eprintfln("mbsc: %s: the Cg backend can't write this shader yet: %s", file, problem)
				}
				return EXIT_ERRORS
			}
			return write_cg(programs, output)
		}
		if emit_pica {
			program, problems := generate_pica(ir)
			defer delete(program.vertex)
			defer delete(problems)
			plan, tev_problems := generate_tev(ir)
			defer delete(tev_problems)
			if len(problems) > 0 || len(tev_problems) > 0 {
				for problem in problems {
					fmt.eprintfln("mbsc: %s: the PICA backend can't write this shader yet: %s", file, problem)
				}
				for problem in tev_problems {
					fmt.eprintfln("mbsc: %s: the 3DS fragment stage can't be written: %s", file, problem)
				}
				return EXIT_ERRORS
			}
			table := format_tev(plan)
			defer delete(table)
			if len(output) == 0 {
				fmt.printfln("; ---- vertex program (.v.pica) ----\n%s\n; ---- fragment plan (.tev) ----\n%s", program.vertex, table)
				return EXIT_OK
			}
			if code := write_output(program.vertex, strings.concatenate({output, ".v.pica"}, context.temp_allocator)); code != EXIT_OK {
				return code
			}
			return write_output(table, strings.concatenate({output, ".tev"}, context.temp_allocator))
		}
		if emit_reflection {
			text: string
			problems: []string
			switch target {
			case .PC:
				text, problems = generate_reflection(ir)
			case .VITA:
				text, problems = generate_reflection_vita(ir)
			case .PICA200:
				text, problems = generate_reflection_pica(ir)
			}
			defer delete(text)
			defer delete(problems)
			if len(problems) > 0 {
				for problem in problems {
					fmt.eprintfln("mbsc: %s: can't describe this shader yet: %s", file, problem)
				}
				return EXIT_ERRORS
			}
			return write_output(text, output)
		}
		fmt.printfln("mbsc: %s: no errors found (code generation is not written yet)", file)
		return EXIT_OK
	}

	text := render_errors(parsed, file)
	defer delete(text)
	fmt.fprint(os.stderr, text)
	return EXIT_ERRORS
}

// write_cg writes the two programs to <name>_v.cg and <name>_f.cg, or prints both when no name is given.
write_cg :: proc(programs: Cg_Output, name: string) -> int {
	if len(name) == 0 {
		fmt.printfln("// ---- vertex program (_v.cg) ----\n%s\n// ---- fragment program (_f.cg) ----\n%s", programs.vertex, programs.fragment)
		return EXIT_OK
	}
	vertex_file := strings.concatenate({name, "_v.cg"}, context.temp_allocator)
	fragment_file := strings.concatenate({name, "_f.cg"}, context.temp_allocator)
	if code := write_output(programs.vertex, vertex_file); code != EXIT_OK {
		return code
	}
	return write_output(programs.fragment, fragment_file)
}

// write_output prints text, or writes it to the file named by -o:.
write_output :: proc(text: string, file: string) -> int {
	if len(file) > 0 {
		if write_error := os.write_entire_file(file, transmute([]byte)text); write_error != nil {
			fmt.eprintfln("mbsc: can't write %s: %v", file, write_error)
			return EXIT_USAGE
		}
		return EXIT_OK
	}
	fmt.print(text)
	return EXIT_OK
}

// render_errors is everything mbsc prints for a shader with errors: the messages in the order they appear in the
// file, each followed by a blank line, then the count. The caller frees the text.
render_errors :: proc(parsed: ^Parsed, file: string) -> string {
	// Messages come from several passes; show them in the order they appear in the file.
	slice.stable_sort_by(parsed.diagnostics[:], proc(a, b: Diagnostic) -> bool {
		if a.label.line != b.label.line {
			return a.label.line < b.label.line
		}
		return a.label.column < b.label.column
	})

	builder := strings.builder_make()
	for diagnostic in parsed.diagnostics {
		text := render_diagnostic(diagnostic)
		strings.write_string(&builder, text)
		strings.write_string(&builder, "\n")
		delete(text)
	}
	fmt.sbprintfln(&builder, "mbsc: %s: %d error(s)", file, len(parsed.diagnostics))
	return strings.to_string(builder)
}

parse_arguments :: proc(args: []string) -> (options: Options, ok: bool) {
	index := 0
	for index < len(args) {
		argument := args[index]
		index += 1

		switch {
		case argument == "--help" || argument == "-h":
			options.help = true
		case argument == "--check":
			options.check = true
		case argument == "--dump-ir":
			options.dump_ir = true
		case argument == "--emit-hlsl":
			options.emit_hlsl = true
		case argument == "--emit-cg":
			options.emit_cg = true
		case argument == "--emit-pica":
			options.emit_pica = true
		case argument == "--emit-reflection":
			options.emit_reflection = true
		case argument == "--explain":
			if index >= len(args) {
				fmt.eprintln("mbsc: --explain needs an error code, for example --explain MBS-E12")
				return {}, false
			}
			options.explain = args[index]
			index += 1
		case strings.has_prefix(argument, "-o:"):
			options.output = argument[len("-o:"):]
			if len(options.output) == 0 {
				fmt.eprintln("mbsc: -o: needs a file name, for example -o:mesh.pc.hlsl")
				return {}, false
			}
		case strings.has_prefix(argument, "-target:"):
			target, target_ok := parse_target(argument[len("-target:"):])
			if target_ok == false {
				fmt.eprintfln("mbsc: unknown target '%s'; use pc, vita or 3ds", argument[len("-target:"):])
				return {}, false
			}
			options.target = target
			options.has_target = true
		case strings.has_prefix(argument, "-"):
			fmt.eprintfln("mbsc: unknown option '%s'", argument)
			return {}, false
		case:
			if len(options.file) > 0 {
				fmt.eprintfln("mbsc: one shader at a time; got '%s' and '%s'", options.file, argument)
				return {}, false
			}
			options.file = argument
		}
	}
	return options, true
}

parse_target :: proc(name: string) -> (target: Target, ok: bool) {
	switch name {
	case "pc":
		return .PC, true
	case "vita":
		return .VITA, true
	case "3ds":
		return .PICA200, true
	}
	return {}, false
}

// explain prints one entry of docs/shader_errors.md.
explain :: proc(text: string) -> int {
	code, valid := normalize_code(text)
	if valid == false {
		fmt.eprintfln("mbsc: '%s' isn't an error code; they look like MBS-E12", text)
		return EXIT_USAGE
	}
	defer delete(code)

	entry, found := find_entry(ERRORS_DOC, code)
	if found == false {
		fmt.eprintfln("mbsc: no entry for %s; the errors are MBS-E1 to MBS-E%d", code, last_error_number(ERRORS_DOC))
		return EXIT_ERRORS
	}
	defer delete(entry)

	fmt.print(entry)
	return EXIT_OK
}
