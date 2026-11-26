package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// The Cg backend (S4): the intermediate form (ir.odin) written as Cg for Sony's `psp2cgc`, which makes the `.gxp`
// programs the Vita runs. A shader gives two files, `<name>_v.cg` (the vertex program) and `<name>_f.cg` (the
// fragment program), the names `tools/build_shaders.py` in the vito repo compiles.
//
// What the output relies on, and why:
//   - The runtime passes Odin's matrix memory unchanged, and Cg reads that memory as the transposed matrix: an Odin
//     `matrix[R, C]f32` is a Cg `floatCxR`. So `m * v` is `mul(v, m)`, `v * m` is `mul(m, v)` and `m * n` is
//     `mul(n, m)`, and a matrix written out element by element is written transposed.
//   - There are no constant buffers. Every uniform is a global `uniform` named like its HLSL counterpart
//     (`<block>_<field>` for the engine's blocks), and the runtime finds it by that name. The compiler drops the ones
//     a program doesn't read.
//   - The entry point of each program is a `main` wrapper. It takes the vertex attributes as plain parameters named
//     `a_<attr>` (the runtime finds them by name), or the varying fields as `TEXCOORD`, `COLOR0` and `WPOS`
//     inputs, builds the shader's structs from them and calls `vertex_main` or `fragment_main`.
//   - A texture is `uniform sampler2D name : TEXUNIT<slot>`. The vertex program samples with an explicit level (there
//     are no derivatives there), the fragment program with `tex2D`.
//   - Each file holds only the procedures its stage runs, so `discard` and the like never reach the vertex program.

// Words a shader can't use as names in Cg, and intrinsics it would hide. A shader name that matches one gets
// `mbs_` in front of it.
@(rodata, private = "file")
RESERVED := [?]string {
	// keywords
	"asm", "bool", "break", "buffer", "case", "cbuffer", "centroid", "class", "column_major", "compile", "const",
	"continue", "default", "discard", "do", "double", "else", "extern", "false", "float", "for", "groupshared",
	"half", "if", "in", "inline", "inout", "int", "interface", "line", "lineadj", "linear", "matrix", "namespace",
	"nointerpolation", "noperspective", "out", "packoffset", "pixelshader", "point", "precise", "register",
	"return", "row_major", "sample", "sampler", "SamplerState", "shared", "snorm", "static", "string", "struct",
	"switch", "tbuffer", "technique", "Texture2D", "texture", "triangle", "triangleadj", "true", "typedef",
		"main", "fixed", "sampler1D", "sampler2D", "sampler3D", "samplerCUBE", "tex1D", "tex2D", "tex3D", "texCUBE",
		"tex2Dlod", "tex2Dbias", "tex2Dgrad", "tex2Dproj", "POSITION", "COLOR", "COLOR0", "TEXCOORD0", "WPOS", "TEXUNIT0",
	"uint", "uniform", "unorm", "unsigned", "vector", "vertexshader", "void", "volatile", "while",
	// intrinsics a shader could be tempted to name something after
	"abs", "acos", "all", "any", "asin", "atan", "atan2", "ceil", "clamp", "clip", "cos", "cosh", "cross", "ddx",
	"ddy", "degrees", "determinant", "distance", "dot", "exp", "exp2", "floor", "fmod", "frac", "fwidth",
	"isfinite", "isinf", "isnan", "ldexp", "length", "lerp", "lit", "log", "log10", "log2", "mad", "max", "min",
	"modf", "mul", "normalize", "pow", "radians", "rcp", "reflect", "refract", "round", "rsqrt", "saturate",
	"sign", "sin", "sincos", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh", "transpose", "trunc",
}

@(private = "file")
Cg :: struct {
	ir:          ^IR_Module,
	problems:    [dynamic]string,
	globals:     map[string]bool, // names taken at the top level
	names:       map[^IR_Var]string, // what each variable of the procedure being written is called
	helpers:     [dynamic]string, // structs the shader builds, in the order they were first met
	helper_seen: map[string]bool,
	math:        [dynamic]Math_Helper, // built-ins that become a small function, in the order they were first met
	math_seen:   map[string]bool,
	current:     string, // the procedure being written
	calls:       map[string][dynamic]string, // the procedures each procedure calls
	vertex:      bool, // writing the text for the vertex program (true) or the fragment program (false)
	lights:      bool, // a light built-in is called: the lights uniforms and their functions are written
	light_arguments: string, // what the first light built-in was called with: the other must match it (see expr)
	lights_declared: bool, // the shader declares the lights block itself: its uniforms are written in both programs
}

// The two programs of a shader.
Cg_Output :: struct {
	vertex:   string,
	fragment: string,
}

// generate_cg writes the module as two Cg programs. `problems` lists what this backend can't write yet; when it
// isn't empty the text is not complete. Everything is allocated with `allocator`.
generate_cg :: proc(ir: ^IR_Module, allocator := context.allocator) -> (output: Cg_Output, problems: []string) {
	// The text is built in a scratch arena, because writing it allocates many small strings.
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	h := Cg {
		ir = ir,
	}
	reserve_global_names(&h)

	// Every procedure is written once for each program, since a sample is written differently in each. The calls
	// each procedure makes show which of them a program needs.
	vertex_bodies := make(map[string]string)
	fragment_bodies := make(map[string]string)
	for pass in 0 ..< 2 {
		h.vertex = pass == 0
		for info in ir.procs {
			piece := strings.builder_make()
			h.current = info.name
			write_proc(&h, &piece, info)
			if h.vertex {
				vertex_bodies[info.name] = strings.to_string(piece)
			} else {
				fragment_bodies[info.name] = strings.to_string(piece)
			}
		}
	}
	in_vertex := reachable_from(&h, ir.vertex_main)
	in_fragment := reachable_from(&h, ir.fragment_main)

	vertex_text := write_program(&h, true, vertex_bodies, in_vertex)
	fragment_text := write_program(&h, false, fragment_bodies, in_fragment)

	kept_problems := make([]string, len(h.problems), allocator)
	for problem, index in h.problems {
		kept_problems[index] = strings.clone(problem, allocator)
	}
	return Cg_Output{vertex = strings.clone(vertex_text, allocator), fragment = strings.clone(fragment_text, allocator)}, kept_problems
}

// write_program is the text of one program: the structs, the uniforms, the helpers, the procedures the stage runs
// and the `main` that wraps the entry point.
@(private = "file")
write_program :: proc(h: ^Cg, vertex: bool, bodies: map[string]string, wanted: map[string]bool) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "// Generated by mbsc. Edit the .mbs shader and generate this file again; changes made here are lost.\n")
	write_structs(h, &builder)
	write_uniforms(h, &builder)
	write_helpers(h, &builder, vertex)
	for info in h.ir.procs {
		if wanted[info.name] {
			strings.write_string(&builder, bodies[info.name])
		}
	}
	if vertex {
		write_vertex_main(h, &builder)
	} else {
		write_fragment_main(h, &builder)
	}
	return strings.to_string(builder)
}

// reachable_from is the names of the procedures an entry point runs, itself included.
@(private = "file")
reachable_from :: proc(h: ^Cg, entry: ^IR_Proc) -> map[string]bool {
	seen := make(map[string]bool)
	if entry == nil {
		return seen
	}
	pending := make([dynamic]string)
	append(&pending, entry.name)
	for len(pending) > 0 {
		name := pop(&pending)
		if seen[name] {
			continue
		}
		seen[name] = true
		for callee in h.calls[name] {
			append(&pending, callee)
		}
	}
	return seen
}

// ---- names ------------------------------------------------------------------------------------------------

@(private = "file")
is_reserved :: proc(name: string) -> bool {
	for word in RESERVED {
		if word == name {
			return true
		}
	}
	return false
}

// safe_name is a shader's name as Cg can take it.
@(private = "file")
safe_name :: proc(name: string) -> string {
	if is_reserved(name) || strings.has_prefix(name, "mbs_") {
		return strings.concatenate({"mbs_", name})
	}
	return name
}

@(private = "file")
reserve_global_names :: proc(h: ^Cg) {
	for info in h.ir.structs {
		h.globals[safe_name(info.name)] = true
	}
	for texture in h.ir.textures {
		h.globals[safe_name(texture.name)] = true
	}
	for uniform in h.ir.uniforms {
		if uniform.kind == .GAME {
			h.globals[safe_name(uniform.name)] = true
		} else {
			for field in get_engine_fields(uniform.kind) {
				h.globals[block_field_name(uniform.name, field.name)] = true
			}
		}
	}
	for info in h.ir.procs {
		h.globals[safe_name(info.name)] = true
	}
}

@(private = "file")
block_field_name :: proc(block, field: string) -> string {
	return strings.concatenate({safe_name(block), "_", field})
}

// local_name picks the name of a variable. It keeps the shader's own name unless another variable of the
// procedure, or something at the top level, already has it; then the variable's number is added.
@(private = "file")
local_name :: proc(h: ^Cg, taken: ^map[string]bool, var: ^IR_Var) -> string {
	candidate := safe_name(var.name)
	if var.name == "_" {
		candidate = "unused"
	}
	if taken[candidate] || h.globals[candidate] || candidate == "unused" {
		candidate = fmt.aprintf("%s_%d", candidate, var.id)
	}
	taken[candidate] = true
	h.names[var] = candidate
	return candidate
}

// ---- types ------------------------------------------------------------------------------------------------

// base_type is a type without any array part: `float4`, `float4x4`, `Varying`.
@(private = "file")
base_type :: proc(h: ^Cg, type: ^Type) -> string {
	#partial switch type.kind {
	case .BOOL:
		return "bool"
	case .F32:
		return "float"
	case .I32:
		return "int"
	case .U32:
		return "uint"
	case .VECTOR:
		return fmt.aprintf("%s%d", base_type(h, type.elem), type.count)
	case .MATRIX:
		// Odin's memory, read by Cg: the columns of an Odin matrix are the rows of the Cg one
		return fmt.aprintf("float%dx%d", type.cols, type.rows)
	case .ARRAY:
		return base_type(h, type.elem)
	case .STRUCT:
		return safe_name(type.info.name)
	case .TEXTURE2D:
		return "sampler2D"
	}
	return "void"
}

// array_suffix is `[2][3]` for the array part of a type, outermost first, and "" for a type that isn't an array.
@(private = "file")
array_suffix :: proc(type: ^Type) -> string {
	suffix := ""
	current := type
	for current.kind == .ARRAY {
		suffix = fmt.aprintf("%s[%d]", suffix, current.count)
		current = current.elem
	}
	return suffix
}

// declarator is a name with its type, the way Cg writes it: `float4 a[3]`.
@(private = "file")
declarator :: proc(h: ^Cg, type: ^Type, name: string) -> string {
	return fmt.aprintf("%s %s%s", base_type(h, type), name, array_suffix(type))
}

// engine_type turns the engine tables' type spelling into Cg.
@(private = "file")
engine_type :: proc(key: string) -> string {
	switch {
	case key == "f32":
		return "float"
	case key == "[2]f32":
		return "float2"
	case key == "[3]f32":
		return "float3"
	case key == "[4]f32":
		return "float4"
	case key == "[JOINT_SLOT_COUNT][4]f32":
		return "float4" // the array suffix names the count (engine_array_suffix)
	case strings.has_prefix(key, "matrix[") && len(key) == len("matrix[4,4]f32"):
		return fmt.aprintf("float%cx%c", key[9], key[7])
	}
	return "float"
}

// semantic is what an `out:` tag means in Cg. "" for a field that has none, and for the ones that travel in a
// TEXCOORD of their own choosing (see varying_semantics).
@(private = "file")
semantic :: proc(field: IR_Field_Info) -> string {
	switch field.out {
	case "position":
		return "POSITION"
	case "color":
		return "COLOR0"
	case "texcoord0":
		return "TEXCOORD0"
	case "texcoord1":
		return "TEXCOORD1"
	case "texcoord2":
		return "TEXCOORD2"
	}
	return ""
}

// varying_semantics gives every field of the varying struct its semantic: the tagged ones as tagged, the others
// the next TEXCOORD no tagged field uses.
@(private = "file")
varying_semantics :: proc(h: ^Cg, info: IR_Struct) -> []string {
	result := make([]string, len(info.fields))
	next := 3
	for field, index in info.fields {
		result[index] = semantic(field)
		if result[index] == "" {
			result[index] = fmt.aprintf("TEXCOORD%d", next)
			next += 1
		}
	}
	return result
}

// ---- declarations -----------------------------------------------------------------------------------------

// write_structs writes the shader's structs, each after the structs it contains.
@(private = "file")
write_structs :: proc(h: ^Cg, builder: ^strings.Builder) {
	written := make(map[string]bool)
	for info in h.ir.structs {
		write_struct(h, builder, info, &written)
	}
}

@(private = "file")
write_struct :: proc(h: ^Cg, builder: ^strings.Builder, info: IR_Struct, written: ^map[string]bool) {
	if written[info.name] {
		return
	}
	written[info.name] = true

	for field in info.fields {
		inner := field.type
		for inner.kind == .ARRAY {
			inner = inner.elem
		}
		if inner.kind == .STRUCT {
			for other in h.ir.structs {
				if other.name == inner.info.name {
					write_struct(h, builder, other, written)
				}
			}
		}
	}

	fmt.sbprintf(builder, "\nstruct %s {{\n", safe_name(info.name))
	for field in info.fields {
		fmt.sbprintfln(builder, "    %s;", declarator(h, field.type, safe_name(field.name)))
	}
	fmt.sbprintln(builder, "};")
}

@(private = "file")
write_uniforms :: proc(h: ^Cg, builder: ^strings.Builder) {
	for uniform in h.ir.uniforms {
		if uniform.kind == .GAME {
			continue
		}
		// the lights block is written by write_helpers, once, with what the built-ins read
		if uniform.kind == .LIGHTS {
			h.lights_declared = true
			continue
		}
		fmt.sbprintfln(builder, "\n// %s", uniform.name)
		for field in get_engine_fields(uniform.kind) {
			fmt.sbprintfln(builder, "uniform %s %s%s;", engine_type(field.type), block_field_name(uniform.name, field.name), engine_array_suffix(field.type, h.ir.target))
		}
	}
	for uniform in h.ir.uniforms {
		if uniform.kind != .GAME {
			continue
		}
		if uniform.type.kind == .STRUCT && uniform.type.info.name == "" {
			problem(h, fmt.aprintf("the uniform `%s` is a struct written inline; declare the struct with a name first", uniform.name))
			continue
		}
		fmt.sbprintfln(builder, "uniform %s;", declarator(h, uniform.type, safe_name(uniform.name)))
	}
	if len(h.ir.textures) > 0 {
		fmt.sbprintln(builder)
	}
	for texture in h.ir.textures {
		fmt.sbprintfln(builder, "uniform sampler2D %s : TEXUNIT%d;", safe_name(texture.name), texture.slot)
	}
}

// The attribute a vertex field reads is named `a_<attr>`, which the runtime looks up; a field with no `attr:` tag
// keeps its own name.
@(private = "file")
attribute_name :: proc(field: IR_Field_Info) -> string {
	if field.attr != "" {
		return strings.concatenate({"a_", field.attr})
	}
	return strings.concatenate({"a_", field.name})
}

@(private = "file")
struct_of :: proc(h: ^Cg, type: ^Type) -> (IR_Struct, bool) {
	if type != nil && type.kind == .STRUCT {
		for info in h.ir.structs {
			if info.name == type.info.name {
				return info, true
			}
		}
	}
	return {}, false
}

// write_vertex_main wraps `vertex_main`: attributes in, the varying fields out.
@(private = "file")
write_vertex_main :: proc(h: ^Cg, builder: ^strings.Builder) {
	entry := h.ir.vertex_main
	input_struct, has_input := struct_of(h, entry.params[0].type)
	output_struct, has_output := struct_of(h, entry.result)
	if has_input == false || has_output == false {
		problem(h, "`vertex_main` must take and return structs")
		return
	}
	semantics := varying_semantics(h, output_struct)

	fmt.sbprintf(builder, "\nvoid main(")
	for field, index in input_struct.fields {
		if index > 0 {
			fmt.sbprint(builder, ", ")
		}
		fmt.sbprint(builder, declarator(h, field.type, attribute_name(field)))
	}
	for field, index in output_struct.fields {
		fmt.sbprintf(builder, ",\n          out %s : %s", declarator(h, field.type, strings.concatenate({"o_", field.name})), semantics[index])
	}
	fmt.sbprintln(builder, ") {")
	fmt.sbprintfln(builder, "    %s input = (%s)0;", safe_name(input_struct.name), safe_name(input_struct.name))
	for field in input_struct.fields {
		fmt.sbprintfln(builder, "    input.%s = %s;", safe_name(field.name), attribute_name(field))
	}
	fmt.sbprintfln(builder, "    %s result = %s(input);", safe_name(output_struct.name), safe_name(entry.name))
	for field in output_struct.fields {
		fmt.sbprintfln(builder, "    o_%s = result.%s;", field.name, safe_name(field.name))
	}
	fmt.sbprintln(builder, "}")
}

// write_fragment_main wraps `fragment_main`: the varying fields in, a colour out.
@(private = "file")
write_fragment_main :: proc(h: ^Cg, builder: ^strings.Builder) {
	entry := h.ir.fragment_main
	varying, ok := struct_of(h, entry.params[0].type)
	if ok == false {
		problem(h, "`fragment_main` must take a struct")
		return
	}
	semantics := varying_semantics(h, varying)

	fmt.sbprint(builder, "\nfloat4 main(")
	for field, index in varying.fields {
		if index > 0 {
			fmt.sbprint(builder, ",\n            ")
		}
		// the position the fragment stage sees is the pixel's, as `SV_POSITION` is in HLSL
		semantic := "WPOS" if semantics[index] == "POSITION" else semantics[index]
		fmt.sbprintf(builder, "%s : %s", declarator(h, field.type, strings.concatenate({"i_", field.name})), semantic)
	}
	fmt.sbprintln(builder, ") : COLOR {")
	fmt.sbprintfln(builder, "    %s v = (%s)0;", safe_name(varying.name), safe_name(varying.name))
	for field in varying.fields {
		fmt.sbprintfln(builder, "    v.%s = i_%s;", safe_name(field.name), field.name)
	}
	fmt.sbprintfln(builder, "    return %s(v);", safe_name(entry.name))
	fmt.sbprintln(builder, "}")
}

@(private = "file")
problem :: proc(h: ^Cg, text: string) {
	append(&h.problems, text)
}

// ---- helpers for building structs -------------------------------------------------------------------------

@(private = "file")
helper_name :: proc(struct_name: string) -> string {
	return fmt.aprintf("mbs_make_%s", struct_name)
}

// Math_Helper is `mod`, `round`, `sin_approx` or `cos_approx` for one argument type. Cg allows several functions with one
// name, so each type gets its own `mbs_mod(float3, float3)` and so on.
@(private = "file")
Math_Helper :: struct {
	name:          string, // "mod", "round", "sin_approx" or "cos_approx"
	type:          string, // the Cg type of the first argument and the result: float, float2, float3, float4
	scalar_second: bool, // `mod(v, 2.0)`: the second argument is one float for every component
}

// SIN_COEFFICIENTS and COS_COEFFICIENTS are the polynomials of docs/shader_language.md, section 15, highest
// power first. They are the same numbers on every target, so a shader gives the same picture on each.
@(rodata, private = "file")
SIN_COEFFICIENTS := [?]string{"2.1478728533851322e-06", "-0.0001926499619928568", "0.008308984952537351", "-0.16662438501484986", "0.9999793879828708"}

@(rodata, private = "file")
COS_COEFFICIENTS := [?]string{"-2.1978878103077777e-07", "2.4204400324072683e-05", "-0.001385891587244809", "0.041659822182074986", "-0.4999942680922626", "0.9999992215743202"}

@(private = "file")
use_math_helper :: proc(h: ^Cg, name: string, first: ^Type, second: ^Type) -> string {
	helper := Math_Helper {
		name          = name,
		type          = base_type(h, first),
		scalar_second = second != nil && first.kind == .VECTOR && second.kind == .F32,
	}
	key := fmt.aprintf("%s|%s|%v", helper.name, helper.type, helper.scalar_second)
	if h.math_seen[key] == false {
		h.math_seen[key] = true
		append(&h.math, helper)
	}
	return fmt.aprintf("mbs_%s", name)
}

@(private = "file")
write_math_helpers :: proc(h: ^Cg, builder: ^strings.Builder) {
	for helper in h.math {
		switch helper.name {
		case "mod":
			// Odin's `linalg.mod`: the result has the sign of `b`
			second := "float" if helper.scalar_second else helper.type
			fmt.sbprintfln(builder, "\n%s mbs_mod(%s a, %s b) {{", helper.type, helper.type, second)
			fmt.sbprintln(builder, "    return a - b * floor(a / b);")
			fmt.sbprintln(builder, "}")
		case "round":
			// the nearest whole number, a half going to the even neighbour (HLSL's `round`, Cg's rounds halves away
			// from zero): `r - step(0.5, r - x)` takes one off when `floor(x + 0.5)` went up from a half and is odd
			fmt.sbprintfln(builder, "\n%s mbs_round(%s x) {{", helper.type, helper.type)
			fmt.sbprintfln(builder, "    %s r = floor(x + 0.5);", helper.type)
			fmt.sbprintfln(builder, "    %s odd = abs(r - 2.0 * floor(r * 0.5));", helper.type)
			fmt.sbprintln(builder, "    return r - step(0.5, r - x) * odd;")
			fmt.sbprintln(builder, "}")
		case "sin_approx":
			write_polynomial_helper(builder, helper.type, "sin_approx", SIN_COEFFICIENTS[:], "r * p")
		case "cos_approx":
			write_polynomial_helper(builder, helper.type, "cos_approx", COS_COEFFICIENTS[:], "p")
		case "normal_quaternion":
			// The rotation taking +Z to n, as the 3DS's L0 formula and the HLSL helper write it (docs/shader_pica.md)
			fmt.sbprintln(builder, "\nfloat4 mbs_normal_quaternion(float3 n) {")
			fmt.sbprintln(builder, "    return normalize(float4(-n.y, n.x, 0.0, max(1.0 + n.z, 0.00001)));")
			fmt.sbprintln(builder, "}")
		}
	}
}

// write_polynomial_helper writes the argument reduction and the Horner evaluation of section 15.
@(private = "file")
write_polynomial_helper :: proc(builder: ^strings.Builder, type: string, name: string, coefficients: []string, result: string) {
	fmt.sbprintfln(builder, "\n%s mbs_%s(%s x) {{", type, name, type)
	fmt.sbprintfln(builder, "    %s k = floor(x * 0.15915494309189535 + 0.5);", type)
	fmt.sbprintfln(builder, "    %s r = x - 6.283185307179586 * k;", type)
	fmt.sbprintfln(builder, "    %s t = r * r;", type)
	fmt.sbprintfln(builder, "    %s p = %s;", type, coefficients[0])
	for coefficient in coefficients[1:] {
		fmt.sbprintfln(builder, "    p = p * t %s %s;", "-" if coefficient[0] == '-' else "+", coefficient[1:] if coefficient[0] == '-' else coefficient)
	}
	fmt.sbprintfln(builder, "    return %s;", result)
	fmt.sbprintln(builder, "}")
}

// write_light_uniforms declares the lights block, as uniforms the runtime finds by name: what the light built-ins
// read, and what a shader that declares `@(uniform = .LIGHTS) lights` reads itself.
@(private = "file")
write_light_uniforms :: proc(builder: ^strings.Builder) {
	count := get_max_lights(.VITA)
	fmt.sbprintln(builder, "\n// the engine's lights")
	fmt.sbprintfln(builder, "uniform float4 %s;", LIGHT_UNIFORM_NAMES[0])
	for name in LIGHT_UNIFORM_NAMES[1:] {
		fmt.sbprintfln(builder, "uniform float4 %s[%d];", name, count)
	}
	// Where each kind's run ends in the sorted lights, and the total: suns, then bulbs, then the whole. A float, not
	// an int: the runtime sets uniforms as floats (CG_LIGHT_FUNCTIONS says why the lights are sorted)
	fmt.sbprintln(builder, "uniform float3 lights_split;")
}

// write_light_functions_for writes the functions the light built-ins call (lighting.odin), and the material
// uniforms they read when the shader didn't declare `render` itself.
@(private = "file")
write_light_functions_for :: proc(h: ^Cg, builder: ^strings.Builder) {
	render_block := ""
	for uniform in h.ir.uniforms {
		if uniform.kind == .RENDER {
			render_block = safe_name(uniform.name)
		}
	}
	if render_block == "" {
		// the specular reads the part's material from the render block, which this shader didn't declare
		render_block = "render"
		for field in RENDER_FIELDS {
			fmt.sbprintfln(builder, "uniform %s %s;", engine_type(field.type), block_field_name(render_block, field.name))
		}
	}
	write_light_functions_cg(builder, render_block)
}

@(private = "file")
write_helpers :: proc(h: ^Cg, builder: ^strings.Builder, vertex: bool) {
	// The light built-ins are fragment only (MBS-E26 refuses them in a vertex stage), so their functions go in the
	// fragment program alone; `h.lights` is set for the shader as a whole, hence the stage check. A declared lights
	// block may be read in either stage, so its uniforms go in both, and psp2cgc drops them from one that doesn't
	if h.lights_declared || (h.lights && !vertex) {
		write_light_uniforms(builder)
	}
	if h.lights && !vertex {
		write_light_functions_for(h, builder)
	}
	write_math_helpers(h, builder)
	for struct_name in h.helpers {
		for info in h.ir.structs {
			if info.name != struct_name {
				continue
			}
			fmt.sbprintf(builder, "\n%s %s(", safe_name(info.name), helper_name(info.name))
			for field, index in info.fields {
				if index > 0 {
					fmt.sbprint(builder, ", ")
				}
				fmt.sbprint(builder, declarator(h, field.type, safe_name(field.name)))
			}
			fmt.sbprintfln(builder, ") {{")
			fmt.sbprintfln(builder, "    %s result;", safe_name(info.name))
			for field in info.fields {
				fmt.sbprintfln(builder, "    result.%s = %s;", safe_name(field.name), safe_name(field.name))
			}
			fmt.sbprintln(builder, "    return result;")
			fmt.sbprintln(builder, "}")
		}
	}
}

// ---- procedures and statements ----------------------------------------------------------------------------

@(private = "file")
write_proc :: proc(h: ^Cg, builder: ^strings.Builder, info: ^IR_Proc) {
	clear(&h.names)
	taken := make(map[string]bool)

	if info.result.kind == .ARRAY {
		problem(h, fmt.aprintf("`%s` returns an array, which Cg can't do", info.name))
		return
	}

	result := "void" if info.result.kind == .VOID else base_type(h, info.result)
	fmt.sbprintf(builder, "\n%s %s(", result, safe_name(info.name))
	for param, index in info.params {
		if index > 0 {
			fmt.sbprint(builder, ", ")
		}
		fmt.sbprint(builder, declarator(h, param.type, local_name(h, &taken, param)))
	}
	fmt.sbprint(builder, ")")
	fmt.sbprintln(builder, " {")
	write_statements(h, builder, &taken, info.body, 1)
	fmt.sbprintln(builder, "}")
}

@(private = "file")
write_statements :: proc(h: ^Cg, builder: ^strings.Builder, taken: ^map[string]bool, statements: []^IR_Stmt, depth: int) {
	for statement in statements {
		write_statement(h, builder, taken, statement, depth)
	}
}

@(private = "file")
indent :: proc(builder: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		fmt.sbprint(builder, "    ")
	}
}

@(private = "file")
write_statement :: proc(h: ^Cg, builder: ^strings.Builder, taken: ^map[string]bool, statement: ^IR_Stmt, depth: int) {
	indent(builder, depth)
	switch node in statement.variant {
	case IR_Declare:
		write_declaration(h, builder, taken, node)
	case IR_Assign:
		fmt.sbprintfln(builder, "%s = %s;", expr(h, node.target), bare(h, node.value))
	case IR_If:
		fmt.sbprintfln(builder, "if (%s) {{", bare(h, node.condition))
		write_statements(h, builder, taken, node.then, depth + 1)
		if len(node.otherwise) > 0 {
			indent(builder, depth)
			fmt.sbprintln(builder, "} else {")
			write_statements(h, builder, taken, node.otherwise, depth + 1)
		}
		indent(builder, depth)
		fmt.sbprintln(builder, "}")
	case IR_For:
		counter := local_name(h, taken, node.var)
		compare := "<=" if node.inclusive else "<"
		fmt.sbprintfln(builder, "for (int %s = %s; %s %s %s; %s++) {{", counter, bare(h, node.from), counter, compare, bare(h, node.to), counter)
		write_statements(h, builder, taken, node.body, depth + 1)
		indent(builder, depth)
		fmt.sbprintln(builder, "}")
	case IR_Return:
		if node.value != nil {
			fmt.sbprintfln(builder, "return %s;", bare(h, node.value))
		} else {
			fmt.sbprintln(builder, "return;")
		}
	case IR_Eval:
		fmt.sbprintfln(builder, "%s;", bare(h, node.call))
	case IR_Block:
		fmt.sbprintln(builder, "{")
		write_statements(h, builder, taken, node.body, depth + 1)
		indent(builder, depth)
		fmt.sbprintln(builder, "}")
	}
}

@(private = "file")
write_declaration :: proc(h: ^Cg, builder: ^strings.Builder, taken: ^map[string]bool, node: IR_Declare) {
	// the value is written before the name is chosen: it can't mention the variable it initialises
	value: string
	if node.init == nil {
		value = zero_value(h, node.var.type)
	} else if literal, is_literal := node.init.variant.(IR_Construct); is_literal && node.init.type.kind == .ARRAY {
		value = array_initializer(h, literal)
	} else {
		value = bare(h, node.init)
	}
	name := local_name(h, taken, node.var)
	qualifier := "" if node.var.mutable else "const "
	fmt.sbprintfln(builder, "%s%s = %s;", qualifier, declarator(h, node.var.type, name), value)
}

// array_initializer is `{ a, b, c }`, which Cg allows only where a variable is declared.
@(private = "file")
array_initializer :: proc(h: ^Cg, construct: IR_Construct) -> string {
	return fmt.aprintf("{{ %s }}", list(h, construct.args))
}

@(private = "file")
zero_value :: proc(h: ^Cg, type: ^Type) -> string {
	if type.kind == .ARRAY {
		return fmt.aprintf("(%s%s)0", base_type(h, type), array_suffix(type))
	}
	return fmt.aprintf("(%s)0", base_type(h, type))
}

// ---- expressions ------------------------------------------------------------------------------------------

// bare is an expression for a place that already has its own delimiters or ends at a `;`, so the parentheses that
// wrap the whole of it can go: `(a + b)` becomes `a + b`, and `(a) * (b)` stays as it is.
@(private = "file")
bare :: proc(h: ^Cg, e: ^IR_Expr) -> string {
	text := expr(h, e)
	if len(text) < 2 || text[0] != '(' || text[len(text) - 1] != ')' {
		return text
	}
	depth := 0
	for character, index in transmute([]u8)text {
		if character == '(' {
			depth += 1
		} else if character == ')' {
			depth -= 1
			if depth == 0 && index != len(text) - 1 {
				return text
			}
		}
	}
	return text[1:len(text) - 1]
}

@(private = "file")
list :: proc(h: ^Cg, items: []^IR_Expr) -> string {
	parts := make([]string, len(items))
	for item, index in items {
		parts[index] = expr(h, item)
	}
	return strings.join(parts, ", ")
}

@(private = "file")
expr :: proc(h: ^Cg, e: ^IR_Expr) -> string {
	switch node in e.variant {
	case IR_Float:
		return float_literal(node.value)
	case IR_Int:
		return fmt.aprintf("%d", node.value) if e.type.kind == .I32 else fmt.aprintf("%du", node.value)
	case IR_Bool:
		return "true" if node.value else "false"
	case IR_Zero:
		return zero_value(h, e.type)
	case IR_Var_Ref:
		if name, found := h.names[node.var]; found {
			return name
		}
		return safe_name(node.var.name)
	case IR_Uniform_Ref:
		// a whole engine block can't be named in Cg; only its fields can (see IR_Field below)
		return safe_name(node.name)
	case IR_Texture_Ref:
		return safe_name(node.name)
	case IR_Unary:
		symbol := "-" if node.op == .NEGATE else "!"
		return fmt.aprintf("(%s%s)", symbol, expr(h, node.operand))
	case IR_Binary:
		return binary(h, node)
	case IR_Swizzle:
		components := "xyzw"
		letters: [4]u8
		for index in 0 ..< node.count {
			letters[index] = components[node.indices[index]]
		}
		return fmt.aprintf("%s.%s", expr(h, node.base), string(letters[:node.count]))
	case IR_Field:
		if uniform, is_uniform := node.base.variant.(IR_Uniform_Ref); is_uniform && uniform.kind != .GAME {
			return block_field_name(uniform.name, node.name)
		}
		return fmt.aprintf("%s.%s", expr(h, node.base), safe_name(node.name))
	case IR_Index:
		return fmt.aprintf("%s[%s]", expr(h, node.base), expr(h, node.index))
	case IR_Convert:
		return fmt.aprintf("((%s)(%s))", base_type(h, e.type), expr(h, node.operand))
	case IR_Construct:
		return construct(h, e, node)
	case IR_Builtin_Call:
		return builtin_call(h, e, node)
	case IR_Proc_Call:
		calls := h.calls[h.current]
		append(&calls, node.callee.name)
		h.calls[h.current] = calls
		return fmt.aprintf("%s(%s)", safe_name(node.callee.name), list(h, node.args))
	}
	return "?"
}

@(private = "file")
binary :: proc(h: ^Cg, node: IR_Binary) -> string {
	left, right := expr(h, node.left), expr(h, node.right)
	// `*` between matrices, or a vector and a matrix, is a matrix product; Cg's own `*` works per element. The
	// matrices are the transposed ones (see base_type), so the operands go the other way round.
	if node.op == .MUL {
		left_matrix, right_matrix := node.left.type.kind == .MATRIX, node.right.type.kind == .MATRIX
		is_scale := node.left.type.kind == .F32 || node.right.type.kind == .F32
		if (left_matrix || right_matrix) && is_scale == false {
			return fmt.aprintf("mul(%s, %s)", right, left)
		}
	}
	symbol: string
	switch node.op {
	case .ADD:
		symbol = "+"
	case .SUB:
		symbol = "-"
	case .MUL:
		symbol = "*"
	case .DIV:
		symbol = "/"
	case .LESS:
		symbol = "<"
	case .GREATER:
		symbol = ">"
	case .LESS_EQUAL:
		symbol = "<="
	case .GREATER_EQUAL:
		symbol = ">="
	case .EQUAL:
		symbol = "=="
	case .NOT_EQUAL:
		symbol = "!="
	case .AND:
		symbol = "&&"
	case .OR:
		symbol = "||"
	}
	return fmt.aprintf("(%s %s %s)", left, symbol, right)
}

@(private = "file")
construct :: proc(h: ^Cg, e: ^IR_Expr, node: IR_Construct) -> string {
	#partial switch e.type.kind {
	case .VECTOR:
		return fmt.aprintf("%s(%s)", base_type(h, e.type), list(h, node.args))
	case .MATRIX:
		// the arguments come row by row of the Odin matrix, and the Cg matrix is its transpose
		rows, cols := e.type.rows, e.type.cols
		if len(node.args) != rows * cols {
			problem(h, "a matrix written from vectors isn't written for Cg yet")
			return "?"
		}
		reordered := make([]^IR_Expr, len(node.args))
		for column in 0 ..< cols {
			for row in 0 ..< rows {
				reordered[column * rows + row] = node.args[row * cols + column]
			}
		}
		return fmt.aprintf("%s(%s)", base_type(h, e.type), list(h, reordered))
	case .STRUCT:
		name := e.type.info.name
		if h.helper_seen[name] == false {
			h.helper_seen[name] = true
			append(&h.helpers, name)
		}
		return fmt.aprintf("%s(%s)", helper_name(name), list(h, node.args))
	}
	problem(h, "an array written as a value can only start a variable (`a := [2]f32{...}`), not be passed or returned")
	return "?"
}

@(private = "file")
float_literal :: proc(value: f32) -> string {
	buffer: [32]u8
	text := strconv.write_float(buffer[:], f64(value), 'g', -1, 32, {})
	for character in transmute([]u8)text {
		if character == '.' || character == 'e' || character == 'E' {
			return strings.clone(text)
		}
	}
	return fmt.aprintf("%s.0", text)
}

// ---- built-in functions -----------------------------------------------------------------------------------

// Built-ins that Cg has under another name.
@(rodata, private = "file")
RENAMED := [?][2]string{{"inverse_sqrt", "rsqrt"}, {"ln", "log"}, {"fract", "frac"}, {"to_radians", "radians"}, {"to_degrees", "degrees"}, {"is_nan", "isnan"}, {"is_inf", "isinf"}}

// Built-ins that Cg has under the same name and with the same meaning.
@(rodata, private = "file")
SAME_NAME := [?]string {
	"abs", "floor", "ceil", "trunc", "saturate", "min", "max", "clamp", "fmod", "lerp", "sqrt",
	"exp", "exp2", "log2", "log10", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
	"ldexp", "dot", "length", "distance", "normalize", "cross", "reflect", "refract", "transpose", "determinant",
	"ddx", "ddy", "fwidth",
}

@(private = "file")
builtin_call :: proc(h: ^Cg, e: ^IR_Expr, node: IR_Builtin_Call) -> string {
	switch node.name {
	case "sample":
		if h.vertex {
			// the vertex program has no derivatives to choose a level with, so it reads level 0
			return fmt.aprintf("tex2Dlod(%s, float4(%s, 0.0, 0.0))", expr(h, node.args[0]), expr(h, node.args[1]))
		}
		return fmt.aprintf("tex2D(%s, %s)", expr(h, node.args[0]), expr(h, node.args[1]))
	case "sample_lod":
		return fmt.aprintf("tex2Dlod(%s, float4(%s, 0.0, %s))", expr(h, node.args[0]), expr(h, node.args[1]), expr(h, node.args[2]))
	case "sample_bias":
		return fmt.aprintf("tex2Dbias(%s, float4(%s, 0.0, %s))", expr(h, node.args[0]), expr(h, node.args[1]), expr(h, node.args[2]))
	case "sample_grad":
		return fmt.aprintf("tex2D(%s, %s, %s, %s)", expr(h, node.args[0]), expr(h, node.args[1]), expr(h, node.args[2]), expr(h, node.args[3]))
	case "discard":
		return "discard"
	case "mod", "round":
		return fmt.aprintf("%s(%s)", use_math_helper(h, node.name, node.args[0].type, node.args[1].type if len(node.args) > 1 else nil), list(h, node.args))
	case "light_diffuse", "light_specular":
		h.lights = true
		// Both built-ins run one shared pass over the lights (CG_LIGHT_FUNCTIONS), which only holds for one pair of arguments
		arguments := list(h, node.args)
		if h.light_arguments == "" {
			h.light_arguments = arguments
		} else if h.light_arguments != arguments {
			problem(h, fmt.tprintf("light_diffuse and light_specular are called with different arguments (`%s` and `%s`); the Vita's lights are worked out once for one pair", h.light_arguments, arguments))
		}
		return fmt.aprintf("mbs_%s(%s)", node.name, arguments)
	case "sin_approx", "cos_approx", "normal_quaternion":
		return fmt.aprintf("%s(%s)", use_math_helper(h, node.name, node.args[0].type, nil), list(h, node.args))
	case "dot3_signed":
		// `4 * dot(a.rgb - 0.5, b.rgb - 0.5)`; a fourth component, if there is one, is left out
		suffix := ".xyz" if node.args[0].type.count == 4 else ""
		return fmt.aprintf("(4.0 * dot(%s%s - 0.5, %s%s - 0.5))", expr(h, node.args[0]), suffix, expr(h, node.args[1]), suffix)
	case "sign":
		return fmt.aprintf("((%s)sign(%s))", base_type(h, e.type), list(h, node.args))
	case "step", "smoothstep":
		// Cg wants every argument the same size, where the language lets one be a plain number
		xs := "xxxx"
		parts := make([]string, len(node.args))
		for argument, index in node.args {
			parts[index] = expr(h, argument)
			if argument.type.kind == .F32 && e.type.kind == .VECTOR {
				parts[index] = fmt.aprintf("(%s).%s", parts[index], xs[:e.type.count])
			}
		}
		return fmt.aprintf("%s(%s)", node.name, strings.join(parts, ", "))
	}
	for pair in RENAMED {
		if pair[0] == node.name {
			return fmt.aprintf("%s(%s)", pair[1], list(h, node.args))
		}
	}
	for name in SAME_NAME {
		if name == node.name {
			return fmt.aprintf("%s(%s)", name, list(h, node.args))
		}
	}
	problem(h, fmt.aprintf("`%s` isn't written for Cg yet", node.name))
	return "?"
}
