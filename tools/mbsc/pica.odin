package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:strings"

// The PICA200 vertex backend (S5): the intermediate form (ir.odin) written as PICA assembly for `picasso`, which makes
// the `.shbin` the 3DS runs. The fragment stage is not a program on this hardware; it is the TexEnv plan (S6).
//
// The shape of the output, and why:
//   - Every procedure is inlined into `main`. The hardware has `call`, but inlining needs no calling convention and the
//     capability check already keeps the shader small. A `for` with constant bounds is unrolled.
//   - A value is a list of operands, one per register: a scalar or a vector is one register, a matrix is one register
//     per row (that is how `dp4` wants it), an array or a struct is its elements' or fields' registers one after the
//     other. A vector sits in the lowest components of its register (`[3]f32` in `.xyz`); a scalar is read from any
//     component, and is always written with all four selectors alike.
//   - picasso's operand rules decide what an instruction may take. `add`, `mul`, `max`, `min`, `dp3`, `dp4` and `cmp`
//     take a uniform or a constant only as the first source; `slt`, `sge` and `dph` may take one as the second as well.
//     A constant is never negated in an instruction, and two different input registers never meet in one instruction.
//     `emit_binary` copies an operand to a temporary when the rules need it, or swaps the sources of a commutative
//     instruction.
//   - `rcp`, `rsq`, `ex2` and `lg2` read the first component of their source and write that one result to every
//     component they write, so a vector takes one instruction per component (or one, when the source is a scalar).
//   - Uniforms: a matrix is `.fvec name[rows]`, a vector or scalar `.fvec name`, an array of vectors or scalars
//     `.fvec name[count]`. A struct uniform is split into one name per field, joined with `_` (`light_strength`), and an
//     array of structs into one per element (`lights_1_color`); engine fields are `<block>_<field>`
//     (`frame_view_projection`). Only the uniforms the shader reads are declared.
//   - Constants become `.constf` registers, one per distinct value.

PICA_TEMPORARIES :: 16
PICA_INSTRUCTIONS :: 512
PICA_FLOAT_REGISTERS :: 96

// One declared uniform: what the runtime looks up by name in the `.shbin`.
Pica_Uniform :: struct {
	name:      string,
	type:      ^Type, // the type of the whole declaration (an array when it is declared as one)
	registers: int,
	is_bool:   bool, // a `.bool`, set with the boolean uniform calls instead of the float ones
}

Pica_Output :: struct {
	vertex:    string, // the `.v.pica` file
	uniforms:  []Pica_Uniform, // in the order of declaration
	registers: int, // float registers used by uniforms and constants
}

Pica_Kind :: enum {
	TEMP,
	INPUT,
	UNIFORM,
	CONST,
}

Pica_Operand :: struct {
	kind:      Pica_Kind,
	base:      string, // `r3`, `v1`, `frame_view_projection[2]`, `mbs_k4`
	swz:       [4]u8, // the component each lane reads
	neg:       bool,
	temp:      int, // the register number, for a TEMP
	owned:     bool, // a temporary the expression just made, which the next instruction may let go of
	is_const:  bool, // a CONST with known contents
	const_val: [4]f32,
}

Pica_Value :: []Pica_Operand

Pica_Entry :: struct {
	index:  int,
	pinned: bool,
	depth:  int, // the inline depth of the declaration that pinned it
}

Pica :: struct {
	ir:           ^IR_Module,
	problems:     [dynamic]string,
	body:         strings.Builder,
	outputs_text: strings.Builder, // the `.out` lines
	indent:       int,
	count:        int, // instructions written
	state:        [PICA_TEMPORARIES]int, // 0 free, 1 in use, 2 pinned
	stack:        [dynamic]Pica_Entry,
	highest:      int, // the highest temporary used, plus one
	constants:    [dynamic][4]f32,
	uniforms:     [dynamic]Pica_Uniform,
	uniform_seen: map[string]bool,
	env:          map[^IR_Var]Pica_Value,
	loops:        map[^IR_Var]i64,
	depth:        int, // how many inlined calls deep
	ret:          Pica_Value, // where a nested `return` puts its value
	has_ret:      bool,
}

// generate_pica writes the vertex stage of the module as PICA assembly. `problems` lists what this backend can't write
// yet; when it isn't empty the text is not complete. Everything is allocated with `allocator`.
generate_pica :: proc(ir: ^IR_Module, allocator := context.allocator) -> (output: Pica_Output, problems: []string) {
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.allocator = virtual.arena_allocator(&scratch)

	h := Pica {
		ir   = ir,
		body = strings.builder_make(),
		outputs_text = strings.builder_make(),
	}
	generate_vertex(&h)

	text := pica_finish(&h)
	registers := len(h.constants)
	for uniform in h.uniforms {
		registers += uniform.registers if uniform.is_bool == false else 0
	}
	if registers > PICA_FLOAT_REGISTERS {
		pica_problem(&h, fmt.aprintf("the shader needs %d float registers for uniforms and constants; the 3DS has %d", registers, PICA_FLOAT_REGISTERS))
	}
	if h.count > PICA_INSTRUCTIONS {
		pica_problem(&h, fmt.aprintf("the shader is %d instructions long; the vertex unit takes %d", h.count, PICA_INSTRUCTIONS))
	}
	if h.highest > PICA_TEMPORARIES {
		pica_problem(&h, fmt.aprintf("the shader needs more than %d temporary registers", PICA_TEMPORARIES))
	}

	kept_problems := make([]string, len(h.problems), allocator)
	for message, index in h.problems {
		kept_problems[index] = strings.clone(message, allocator)
	}
	kept_uniforms := make([]Pica_Uniform, len(h.uniforms), allocator)
	for uniform, index in h.uniforms {
		kept_uniforms[index] = uniform
		kept_uniforms[index].name = strings.clone(uniform.name, allocator)
	}
	return Pica_Output{vertex = strings.clone(text, allocator), uniforms = kept_uniforms, registers = registers}, kept_problems
}

pica_problem :: proc(h: ^Pica, text: string) {
	for existing in h.problems {
		if existing == text {
			return
		}
	}
	append(&h.problems, text)
}

// ---- the file -----------------------------------------------------------------------------------------------

@(rodata, private = "file")
PICA_WORDS := [?]string {
	"add", "dp3", "dp4", "dph", "dst", "ex2", "lg2", "litp", "mul", "sge", "slt", "flr", "rcp", "rsq", "mov", "mova",
	"max", "min", "cmp", "call", "callc", "callu", "ifc", "ifu", "for", "loop", "end", "nop", "break", "breakc",
	"jmpc", "jmpu", "emit", "setemit", "mad", "main", "out", "in", "pos", "position", "color", "view", "normalquat",
}

pica_safe_name :: proc(name: string) -> string {
	if strings.has_prefix(name, "mbs_") {
		return strings.concatenate({"mbs_", name})
	}
	// `v3` and `r0` are registers, so a shader's own `v3` can't keep its name
	if len(name) >= 2 && len(name) <= 3 && (name[0] == 'r' || name[0] == 'v' || name[0] == 'c' || name[0] == 'o') {
		digits := true
		for character in transmute([]u8)name[1:] {
			if character < '0' || character > '9' {
				digits = false
			}
		}
		if digits {
			return strings.concatenate({"mbs_", name})
		}
	}
	for word in PICA_WORDS {
		if word == name {
			return strings.concatenate({"mbs_", name})
		}
	}
	return name
}

pica_number :: proc(value: f32) -> string {
	return fmt.aprintf("%.9e", f64(value))
}

pica_finish :: proc(h: ^Pica) -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "; Generated by mbsc. Edit the .mbs shader and generate this file again; changes made here are lost.\n")
	for uniform in h.uniforms {
		if uniform.is_bool {
			fmt.sbprintfln(&builder, ".bool %s", uniform.name)
		} else if uniform.registers > 1 || uniform.type.kind == .MATRIX || uniform.type.kind == .ARRAY {
			fmt.sbprintfln(&builder, ".fvec %s[%d]", uniform.name, uniform.registers)
		} else {
			fmt.sbprintfln(&builder, ".fvec %s", uniform.name)
		}
	}
	for value, index in h.constants {
		fmt.sbprintfln(&builder, ".constf mbs_k%d(%s, %s, %s, %s)", index, pica_number(value[0]), pica_number(value[1]), pica_number(value[2]), pica_number(value[3]))
	}
	fmt.sbprint(&builder, strings.to_string(h.outputs_text))
	fmt.sbprintln(&builder, ".proc main")
	strings.write_string(&builder, strings.to_string(h.body))
	fmt.sbprintln(&builder, "\tend")
	fmt.sbprintln(&builder, ".end")
	return strings.to_string(builder)
}
