package matchbox

/*
	TexEnv plan
	===========
	Reads the `.tev` file mbsc writes for the 3DS (`mbsc shader.mbs -target:3ds --emit-pica`).
	The 3DS has no fragment program: the fragment shader becomes up to six TexEnv stages and
	an alpha test, and this is the list of them. render_3ds_freestanding_arm32.odin applies it
	with citro3d. The format is in docs/shader_pica.md, "The fragment stage".

	Shared, though only the 3DS uses it, because it holds no citro3d type: reading it is plain
	text, and a PC test (shader_tev_test.odin) checks it against mbsc's real output.

	A line it does not understand is an error, never skipped: a stage left out would draw
	something different from the shader with nothing to say so.
*/

import "core:strconv"
import "core:strings"

// The PICA200 has six TexEnv stages. A constant because it sizes Tev_Plan's array
TEV_STAGE_COUNT :: 6

Tev_Source :: enum {
	PRIMARY_COLOR, // the vertex colour, as the vertex shader output it
	TEXTURE0,
	TEXTURE1,
	TEXTURE2,
	TEXTURE3,
	PREVIOUS, // the previous stage's result
	CONSTANT, // the stage's constant colour
	FRAGMENT_PRIMARY, // the fragment lighting unit's ambient and diffuse (light_diffuse in the shader)
	FRAGMENT_SECONDARY, // the fragment lighting unit's specular (light_specular)
}

Tev_Function :: enum {
	REPLACE,
	MODULATE,
	ADD,
	SUBTRACT,
	INTERPOLATE,
	MULTIPLY_ADD,
	ADD_MULTIPLY,
}

Tev_Compare :: enum {
	NEVER,
	ALWAYS,
	EQUAL,
	NOTEQUAL,
	LESS,
	LEQUAL,
	GREATER,
	GEQUAL,
}

/*One input of a stage: where it comes from, and whether it is used as one minus itself*/
Tev_Operand :: struct {
	source:Tev_Source,
	one_minus:bool,
}

Tev_Stage :: struct {
	function:Tev_Function,
	operands:[3]Tev_Operand,
	operand_count:int,

	// The CONSTANT source's colour: a literal, or a uniform the game sets. Only literals are
	// applied yet (game uniforms on the 3DS come with custom shaders)
	constant:[4]f32,
	constant_uniform:string, // empty for a literal
}

Tev_Alpha_Test :: struct {
	enabled:bool,
	function:Tev_Compare, // keeps a pixel when `alpha <function> reference` holds
	reference:f32, // 0..1, when `uniform` is empty
	uniform:string, // the f32 uniform the reference comes from, e.g. render_alpha_cutoff
}

/*
	How the fragment lighting unit is set for this shader (G2 L2, docs/3ds_fragment_lighting_plan.md). All false and
	empty for a shader that doesn't light, whose draws leave the unit off
*/
Tev_Lighting :: struct {
	diffuse:bool, // FRAGMENT_PRIMARY is read
	specular:bool, // FRAGMENT_SECONDARY is read
	table:string, // the specular table, "D0"
	table_input:string, // what indexes it, "NH" (N.H)
	clamp_highlights:bool,
	two_sided:bool, // diffuse on back faces too
	fresnel:string, // "none"
}

Tev_Plan :: struct {
	stages:[TEV_STAGE_COUNT]Tev_Stage,
	stage_count:int,
	alpha_test:Tev_Alpha_Test,
	texture_count:int, // how many `texture` lines there were; each is unit n reading texcoord n
	lighting:Tev_Lighting,
}

/*
	Reads a `.tev` file. On failure `message` names the line and what was wrong with it.
	The strings in the plan point into `text`, so `text` must outlive it (a `#load` does)
*/
parse_tev_plan :: proc(text:string) -> (plan:Tev_Plan, ok:bool, message:string) {
	text := text
	line_number := 0
	saw_header := false

	for line in strings.split_lines_iterator(&text) {
		line_number += 1
		line := strings.trim_space(line)
		if line == "" do continue

		words_buffer:[12]string
		words := split_words(line, words_buffer[:])

		switch words[0] {
		case "mbs-tev":
			// 2 since G2 L2 (the lighting lines and sources); 1 is the same without them, so it reads as it is
			if len(words) != 2 || (words[1] != "1" && words[1] != "2") do return plan, false, tev_error(line_number, "only versions 1 and 2 of the .tev format are known")
			saw_header = true

		case "target":
			if len(words) != 2 || words[1] != "3ds" do return plan, false, tev_error(line_number, "the plan is not for the 3ds")

		case "texture":
			// texture <unit> <name> texcoord <n>: unit n must read texcoord n, the only wiring applied
			if len(words) != 5 || words[3] != "texcoord" do return plan, false, tev_error(line_number, "expected: texture <unit> <name> texcoord <n>")
			unit, unit_ok := strconv.parse_int(words[1])
			coordinate, coordinate_ok := strconv.parse_int(words[4])
			if !unit_ok || !coordinate_ok || unit != plan.texture_count || coordinate != unit {
				return plan, false, tev_error(line_number, "textures must be units 0, 1, ... in order, each reading its own texcoord")
			}
			plan.texture_count += 1

		case "stage":
			if len(words) < 2 do return plan, false, tev_error(line_number, "a stage needs its number")
			index, index_ok := strconv.parse_int(words[1])
			if !index_ok || index != plan.stage_count || index >= TEV_STAGE_COUNT {
				return plan, false, tev_error(line_number, "stages must be numbered 0 to 5, in order")
			}
			stage, stage_message := parse_tev_stage(words[2:])
			if stage_message != "" do return plan, false, tev_error(line_number, stage_message)
			plan.stages[index] = stage
			plan.stage_count += 1

		case "alphatest":
			// alphatest <FUNC> <ref | uniform name>
			if len(words) < 3 do return plan, false, tev_error(line_number, "expected: alphatest <function> <reference | uniform name>")
			function, function_ok := parse_tev_compare(words[1])
			if !function_ok do return plan, false, tev_error(line_number, "unknown alpha test function")
			plan.alpha_test.enabled = true
			plan.alpha_test.function = function
			if words[2] == "uniform" && len(words) == 4 {
				plan.alpha_test.uniform = words[3]
			} else if len(words) == 3 {
				reference, reference_ok := strconv.parse_f32(words[2])
				if !reference_ok do return plan, false, tev_error(line_number, "the alpha test reference is not a number")
				plan.alpha_test.reference = reference
			} else {
				return plan, false, tev_error(line_number, "expected: alphatest <function> <reference | uniform name>")
			}

		case "lighting":
			// lighting [diffuse] [specular]
			if len(words) < 2 do return plan, false, tev_error(line_number, "expected: lighting [diffuse] [specular]")
			for word in words[1:] {
				switch word {
				case "diffuse": plan.lighting.diffuse = true
				case "specular": plan.lighting.specular = true
				case: return plan, false, tev_error(line_number, "a lighting result is `diffuse` or `specular`")
				}
			}

		case "lighting_table":
			// lighting_table <table> <input>: only what mbsc writes, D0 indexed by N.H, is applied yet
			if len(words) != 3 || words[1] != "D0" || words[2] != "NH" do return plan, false, tev_error(line_number, "only `lighting_table D0 NH` is known")
			plan.lighting.table = "D0" // a literal, not a slice of the file text the caller may free
			plan.lighting.table_input = "NH"

		case "lighting_clamp_highlights", "lighting_two_sided":
			if len(words) != 2 || (words[1] != "true" && words[1] != "false") do return plan, false, tev_error(line_number, "expected true or false")
			if words[0] == "lighting_clamp_highlights" do plan.lighting.clamp_highlights = words[1] == "true"
			else do plan.lighting.two_sided = words[1] == "true"

		case "lighting_fresnel":
			if len(words) != 2 || words[1] != "none" do return plan, false, tev_error(line_number, "only `lighting_fresnel none` is known")
			plan.lighting.fresnel = "none"

		case:
			return plan, false, tev_error(line_number, "unknown line")
		}
	}

	if !saw_header do return plan, false, "the .tev file has no `mbs-tev` line"
	if plan.stage_count == 0 do return plan, false, "the .tev file has no stages"
	return plan, true, ""
}

// stage <i> <FUNC> <source0> [source1] [source2] [constant uniform <name> | constant r g b a]
@(private)
parse_tev_stage :: proc(words:[]string) -> (stage:Tev_Stage, message:string) {
	if len(words) < 2 do return stage, "a stage needs a function and at least one source"

	function, function_ok := parse_tev_function(words[0])
	if !function_ok do return stage, "unknown stage function"
	stage.function = function

	rest := words[1:]
	for len(rest) > 0 && rest[0] != "constant" {
		if stage.operand_count == 3 do return stage, "a stage has at most three sources"
		operand, operand_ok := parse_tev_operand(rest[0])
		if !operand_ok do return stage, "unknown stage source"
		stage.operands[stage.operand_count] = operand
		stage.operand_count += 1
		rest = rest[1:]
	}

	if len(rest) > 0 {
		if len(rest) == 3 && rest[1] == "uniform" {
			stage.constant_uniform = rest[2]
		} else if len(rest) == 5 {
			for i in 0 ..< 4 {
				value, value_ok := strconv.parse_f32(rest[1 + i])
				if !value_ok do return stage, "a constant colour needs four numbers"
				stage.constant[i] = value
			}
		} else {
			return stage, "expected: constant uniform <name> | constant r g b a"
		}
	}

	needed := 3 if function == .INTERPOLATE || function == .MULTIPLY_ADD || function == .ADD_MULTIPLY else 1 if function == .REPLACE else 2
	if stage.operand_count != needed do return stage, "the stage has the wrong number of sources for its function"
	return stage, ""
}

@(private)
parse_tev_operand :: proc(word:string) -> (operand:Tev_Operand, ok:bool) {
	word := word
	if strings.has_suffix(word, "!") {
		operand.one_minus = true
		word = word[:len(word) - 1]
	}
	switch word {
	case "PRIMARY_COLOR": operand.source = .PRIMARY_COLOR
	case "TEXTURE0":      operand.source = .TEXTURE0
	case "TEXTURE1":      operand.source = .TEXTURE1
	case "TEXTURE2":      operand.source = .TEXTURE2
	case "TEXTURE3":      operand.source = .TEXTURE3
	case "PREVIOUS":      operand.source = .PREVIOUS
	case "CONSTANT":      operand.source = .CONSTANT
	case "FRAGMENT_PRIMARY":   operand.source = .FRAGMENT_PRIMARY
	case "FRAGMENT_SECONDARY": operand.source = .FRAGMENT_SECONDARY
	case: return operand, false
	}
	return operand, true
}

@(private)
parse_tev_function :: proc(word:string) -> (function:Tev_Function, ok:bool) {
	for candidate in Tev_Function {
		if word == tev_function_name(candidate) do return candidate, true
	}
	return {}, false
}

@(private)
parse_tev_compare :: proc(word:string) -> (compare:Tev_Compare, ok:bool) {
	for candidate in Tev_Compare {
		if word == tev_compare_name(candidate) do return candidate, true
	}
	return {}, false
}

// The names as mbsc writes them, which are the enum values' own names
@(private)
tev_function_name :: proc(function:Tev_Function) -> string {
	switch function {
	case .REPLACE:      return "REPLACE"
	case .MODULATE:     return "MODULATE"
	case .ADD:          return "ADD"
	case .SUBTRACT:     return "SUBTRACT"
	case .INTERPOLATE:  return "INTERPOLATE"
	case .MULTIPLY_ADD: return "MULTIPLY_ADD"
	case .ADD_MULTIPLY: return "ADD_MULTIPLY"
	}
	return ""
}

@(private)
tev_compare_name :: proc(compare:Tev_Compare) -> string {
	switch compare {
	case .NEVER:    return "NEVER"
	case .ALWAYS:   return "ALWAYS"
	case .EQUAL:    return "EQUAL"
	case .NOTEQUAL: return "NOTEQUAL"
	case .LESS:     return "LESS"
	case .LEQUAL:   return "LEQUAL"
	case .GREATER:  return "GREATER"
	case .GEQUAL:   return "GEQUAL"
	}
	return ""
}

// Splits on spaces and tabs into `buffer`, so a line needs no allocation. Words past the
// buffer's end are dropped, which the callers' length checks then report
@(private)
split_words :: proc(line:string, buffer:[]string) -> []string {
	count := 0
	rest := line
	for len(rest) > 0 && count < len(buffer) {
		rest = strings.trim_left_space(rest)
		if rest == "" do break
		end := strings.index_any(rest, " \t")
		if end < 0 do end = len(rest)
		buffer[count] = rest[:end]
		count += 1
		rest = rest[end:]
	}
	return buffer[:count]
}

@(private)
tev_error :: proc(line_number:int, what:string) -> string {
	// Built in the temp allocator: the message is read once, by whoever reports it
	return strings.concatenate({"line ", int_to_text(line_number), ": ", what}, context.temp_allocator)
}

@(private)
int_to_text :: proc(value:int) -> string {
	buffer := make([]u8, 24, context.temp_allocator)
	return strconv.write_int(buffer, i64(value), 10)
}
