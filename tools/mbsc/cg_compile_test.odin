package mbsc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// Compiles generated Cg with Sony's `psp2cgc`, the compiler that makes the Vita's `.gxp` programs. The compiler is
// proprietary and is not in this repository: it is the copy in the vito repo (`tools/psp2cgc.exe`, next to this
// one), or the file named by the PSP2CGC environment variable. Without it these tests do nothing.

@(private = "file")
find_psp2cgc :: proc() -> (path: string, found: bool) {
	if value, set := os.lookup_env("PSP2CGC", context.temp_allocator); set && os.is_file(value) {
		return value, true
	}
	// the tests run from the repository's folder or from tools/mbsc
	for beside in ([?]string{"../vito/tools/psp2cgc.exe", "../../../vito/tools/psp2cgc.exe"}) {
		if os.is_file(beside) {
			return beside, true
		}
	}
	return "", false
}

@(private = "file")
compile_counter: int

// compile_cg returns "" when the program compiles, and otherwise the compiler's own message. `ran` is false when the
// compiler isn't available.
compile_cg :: proc(source: string, vertex: bool) -> (message: string, ran: bool) {
	compiler, found := find_psp2cgc()
	if found == false {
		return "", false
	}
	directory, directory_error := os.temp_directory(context.temp_allocator)
	if directory_error != nil {
		return fmt.aprintf("no temporary folder: %v", directory_error, allocator = context.temp_allocator), true
	}
	// the tests run side by side, so each compile gets files of its own
	suffix := "_v" if vertex else "_f"
	number := sync.atomic_add(&compile_counter, 1)
	input := fmt.aprintf("%s/mbsc_cg_test_%d%s.cg", directory, number, suffix, allocator = context.temp_allocator)
	output := fmt.aprintf("%s/mbsc_cg_test_%d%s.gxp", directory, number, suffix, allocator = context.temp_allocator)
	if write_error := os.write_entire_file(input, source); write_error != nil {
		return fmt.aprintf("can't write %s: %v", input, write_error, allocator = context.temp_allocator), true
	}
	defer os.remove(input)
	defer os.remove(output)

	profile := "sce_vp_psp2" if vertex else "sce_fp_psp2"
	state, stdout, stderr, run_error := os.process_exec(os.Process_Desc{command = {compiler, "-profile", profile, "-W4", "-nocolor", "-o", output, input}}, context.temp_allocator)
	if run_error != nil {
		return fmt.aprintf("can't run %s: %v", compiler, run_error, allocator = context.temp_allocator), true
	}
	if state.exit_code != 0 {
		return strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator), true
	}
	return "", true
}

// expect_cg_compiles fails the test when psp2cgc rejects either program.
expect_cg_compiles :: proc(t: ^testing.T, programs: Cg_Output, what := "", loc := #caller_location) {
	for vertex in ([2]bool{true, false}) {
		text := programs.vertex if vertex else programs.fragment
		message, ran := compile_cg(text, vertex)
		if ran == false {
			return
		}
		if message != "" {
			fmt.eprintfln("--- %s %s ---\n%s------------\n%s", what, "vertex" if vertex else "fragment", text, message)
			testing.expectf(t, false, "psp2cgc rejected the %s program %s", "vertex" if vertex else "fragment", what, loc = loc)
		}
	}
}

// generate_cg_text builds a shader for the Vita and writes its programs; false when it doesn't check or the backend
// can't write it.
generate_cg_text :: proc(t: ^testing.T, source: string, what: string, loc := #caller_location) -> (programs: Cg_Output, ok: bool) {
	parsed := parse_shader("test.mbs", source)
	defer destroy_parsed(parsed)
	if parsed.has_syntax_errors == false {
		check_subset(parsed)
	}
	module: ^Module
	if len(parsed.diagnostics) == 0 {
		module = build_module(parsed, .VITA)
	}
	if len(parsed.diagnostics) > 0 {
		for diagnostic in parsed.diagnostics {
			fmt.eprintfln("--- %s: %s %s (line %d)", what, diagnostic.code, diagnostic.title, diagnostic.label.line)
		}
		testing.expectf(t, false, "%s: the shader should check", what, loc = loc)
		return {}, false
	}
	problems: []string
	programs, problems = generate_cg(lower_module(module), context.temp_allocator)
	if len(problems) > 0 {
		testing.expectf(t, false, "%s: %s", what, strings.join(problems, "\n", context.temp_allocator), loc = loc)
		return {}, false
	}
	return programs, true
}

@(test)
the_vito_compiler_is_found_when_it_is_there :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, found := find_psp2cgc()
	if found == false {
		fmt.eprintln("    (psp2cgc not found: the Cg programs are not compiled by these tests)")
	}
}

// A shader whose fragment stage has a local called NAME, replaced by each word under test
@(private = "file")
RESERVED_NAME_SHADER :: `
@(texture = 0) tex:Texture2D

Vertex_In :: struct {
	position: [3]f32 ` + "`attr:\"position\"`" + `,
	uv: [2]f32 ` + "`attr:\"texcoord\"`" + `,
}

Varying :: struct {
	position: [4]f32 ` + "`out:\"position\"`" + `,
	uv: [2]f32 ` + "`out:\"texcoord0\"`" + `,
}

vertex_main :: proc(input: Vertex_In) -> Varying {
	output: Varying
	output.position = [4]f32{input.position.x, input.position.y, input.position.z, 1.0}
	output.uv = input.uv
	return output
}

fragment_main :: proc(v:Varying) -> [4]f32 {
	NAME := v.uv.x * 2.0
	return [4]f32{NAME, NAME, 0.0, 1.0}
}
`

// Every word psp2cgc rejects as a name, found by trying each one (a local named `column` stopped crt.mbs). A shader's own
// name for something must never reach the Cg unchanged when it is one of these: safe_name puts `mbs_` in front
@(test)
names_psp2cgc_rejects_are_renamed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	words := [?]string {
		"column", "row", "auto", "char", "long", "short", "operator", "template", "this", "public",
		"goto", "float2", "float4x4", "half3", "int2", "bool4", "texture2D", "typename", "virtual",
	}
	for word in words {
		source, _ := strings.replace_all(RESERVED_NAME_SHADER, "NAME", word, context.temp_allocator)
		programs, ok := generate_cg_text(t, source, word)
		if ok == false {
			continue
		}
		// The shader's name is not what Cg is given...
		testing.expectf(t, strings.contains(programs.fragment, fmt.tprintf(" %s = ", word)) == false, "`%s` reached the Cg as it is", word)
		testing.expectf(t, strings.contains(programs.fragment, fmt.tprintf("mbs_%s", word)), "`%s` was not renamed", word)
		// ...and the real compiler takes what it is given (skipped without psp2cgc)
		expect_cg_compiles(t, programs, word)
	}
}
