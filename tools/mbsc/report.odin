package mbsc

import "core:fmt"
import "core:slice"
import "core:strings"

// `mbsc --check` without a target (S7): check the shader for every target and say what compiles where.

ALL_TARGETS :: [?]Target{.PC, .VITA, .PICA200}

target_name :: proc(target: Target) -> string {
	switch target {
	case .PC:
		return "pc"
	case .VITA:
		return "vita"
	case .PICA200:
		return "3ds"
	}
	return "?"
}

// What a target's check found. `messages` holds one rendered message per problem, in file order.
Target_Result :: struct {
	target:   Target,
	messages: [dynamic]string,
	note:     string, // what a passing target says about its backend
}

// check_for_target runs every pass over the shader for one target, as `mbsc -target:<name>` does. The PC backend
// is run too (HLSL generation), so a shader the backend can't write is reported here.
check_for_target :: proc(file, source: string, target: Target) -> Target_Result {
	result := Target_Result {
		target   = target,
		messages = make([dynamic]string),
	}
	parsed := parse_shader(file, source)
	defer destroy_parsed(parsed)

	module: ^Module
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
		if len(parsed.diagnostics) == 0 {
			module = build_module(parsed, target)
		}
	}

	if len(parsed.diagnostics) > 0 {
		slice.stable_sort_by(parsed.diagnostics[:], proc(a, b: Diagnostic) -> bool {
			if a.label.line != b.label.line {
				return a.label.line < b.label.line
			}
			return a.label.column < b.label.column
		})
		for diagnostic in parsed.diagnostics {
			append(&result.messages, render_diagnostic(diagnostic))
		}
		return result
	}

	switch target {
	case .PC:
		ir := lower_module(module)
		text, problems := generate_hlsl(ir)
		defer delete(text)
		defer delete(problems)
		if len(problems) > 0 {
			for problem in problems {
				append(&result.messages, fmt.aprintf("the HLSL backend can't write this shader: %s\n", problem))
			}
		} else {
			result.note = "compiles to HLSL"
		}
	case .VITA:
		result.note = "passes the checks; the Cg backend comes with S4"
	case .PICA200:
		result.note = "passes the checks; the PICA backend comes with S5 and S6"
	}
	return result
}

// check_report writes the report of a check of every target, and says whether every target passed.
check_report :: proc(file, source: string) -> (report: string, passed: bool) {
	results: [len(ALL_TARGETS)]Target_Result
	for target, index in ALL_TARGETS {
		results[index] = check_for_target(file, source, target)
	}

	builder := strings.builder_make()
	passed = true

	// a message every target gives is one problem, shown once
	shared := make([dynamic]string, context.temp_allocator)
	for message in results[0].messages {
		in_all := true
		for other in results[1:] {
			if slice.contains(other.messages[:], message) == false {
				in_all = false
			}
		}
		if in_all {
			append(&shared, message)
		}
	}
	if len(shared) > 0 {
		passed = false
		fmt.sbprintfln(&builder, "all targets:\n")
		for message in shared {
			fmt.sbprintfln(&builder, "%s", message)
		}
	}

	for result in results {
		own := make([dynamic]string, context.temp_allocator)
		for message in result.messages {
			if slice.contains(shared[:], message) == false {
				append(&own, message)
			}
		}
		if len(own) > 0 {
			passed = false
			fmt.sbprintfln(&builder, "%s:\n", target_name(result.target))
			for message in own {
				fmt.sbprintfln(&builder, "%s", message)
			}
		}
	}

	fmt.sbprintfln(&builder, "%s:", file)
	for result in results {
		if len(result.messages) == 0 {
			fmt.sbprintfln(&builder, "  %-5s ok: %s", target_name(result.target), result.note)
		} else if len(result.messages) == 1 {
			fmt.sbprintfln(&builder, "  %-5s 1 problem", target_name(result.target))
		} else {
			fmt.sbprintfln(&builder, "  %-5s %d problems", target_name(result.target), len(result.messages))
		}
	}
	for result in results {
		for message in result.messages {
			delete(message)
		}
		delete(result.messages)
	}
	return strings.to_string(builder), passed
}
