package mbsc

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// The entry points and the two structs that connect them (part 1, section 4):
//
//   vertex_main   :: proc(input: Vertex_In) -> Varying
//   fragment_main :: proc(v: Varying) -> [4]f32
//
// Only the shape is checked here. What happens inside the procedures is the type checker's job (step 4).

@(private = "file")
Signature :: struct {
	param_count:  int,
	param_type:   ^ast.Expr, // the first parameter's type
	result_count: int,
	result_type:  ^ast.Expr, // the first result's type
}

check_entry_points :: proc(module: ^Module) {
	vertex := find_entry(module, "vertex_main")
	fragment := find_entry(module, "fragment_main")

	if vertex != nil {
		check_vertex_main(module, vertex)
	}
	if fragment != nil {
		check_fragment_main(module, fragment)
	}
}

// find_entry returns the procedure, or reports it as missing or not a procedure.
@(private = "file")
find_entry :: proc(module: ^Module, name: string) -> ^Proc_Info {
	found := find_proc(module, name)
	if found != nil {
		return found
	}

	example := "vertex_main :: proc(input: Vertex_In) -> Varying { ... }"
	if name == "fragment_main" {
		example = "fragment_main :: proc(v: Varying) -> [4]f32 { ... }"
	}

	if declared, exists := module.names[name]; exists && declared != nil {
		error(
			module,
			"MBS-E15",
			fmt.aprintf("`%s` must be a procedure", name),
			declared,
			"declared as something else",
			"a shader's entry points are procedures with fixed names",
			fmt.aprintf("write `%s`", example),
		)
		return nil
	}

	pos := tokenizer.Pos {
		offset = len(PACKAGE_PREFIX),
		line   = 1,
		column = len(PACKAGE_PREFIX) + 1,
	}
	if len(module.parsed.file.decls) > 0 {
		pos = module.parsed.file.decls[0].pos
	}
	error(
		module,
		"MBS-E15",
		fmt.aprintf("`%s` is missing", name),
		pos,
		1,
		fmt.aprintf("this shader has no `%s`", name),
		"a shader needs a `vertex_main` and a `fragment_main`",
		fmt.aprintf("add `%s`", example),
	)
	return nil
}

@(private = "file")
signature_of :: proc(lit: ^ast.Proc_Lit) -> Signature {
	signature: Signature
	if lit.type == nil {
		return signature
	}
	if lit.type.params != nil {
		for field in lit.type.params.list {
			signature.param_count += max(len(field.names), 1)
			if signature.param_type == nil {
				signature.param_type = field.type
			}
		}
	}
	if lit.type.results != nil {
		for field in lit.type.results.list {
			signature.result_count += max(len(field.names), 1)
			if signature.result_type == nil {
				signature.result_type = field.type
			}
		}
	}
	return signature
}

@(private = "file")
check_vertex_main :: proc(module: ^Module, entry: ^Proc_Info) {
	module.vertex_main = entry
	signature := signature_of(entry.lit)

	if signature.param_count != 1 {
		error(
			module,
			"MBS-E15",
			"`vertex_main` must take one parameter, the vertex input",
			entry.lit.type,
			fmt.aprintf("takes %d parameters", signature.param_count),
			"the vertex stage reads one struct of vertex attributes",
			"write `vertex_main :: proc(input: Vertex_In) -> Varying`",
		)
	} else {
		module.vertex_in = resolve_struct(module, signature.param_type, "the parameter of `vertex_main`")
		if module.vertex_in != nil {
			check_vertex_input(module, module.vertex_in)
		}
	}

	if signature.result_count != 1 {
		error(
			module,
			"MBS-E15",
			"`vertex_main` must return one value, the varying struct",
			entry.lit.type,
			fmt.aprintf("returns %d values", signature.result_count),
			"the vertex stage hands one struct to the fragment stage",
			"write `vertex_main :: proc(input: Vertex_In) -> Varying`",
		)
		return
	}
	module.varying = resolve_struct(module, signature.result_type, "the result of `vertex_main`")
	if module.varying != nil {
		check_varying(module, module.varying)
	}
}

@(private = "file")
check_fragment_main :: proc(module: ^Module, entry: ^Proc_Info) {
	module.fragment_main = entry
	signature := signature_of(entry.lit)

	if signature.param_count != 1 {
		error(
			module,
			"MBS-E15",
			"`fragment_main` must take one parameter, the varying struct",
			entry.lit.type,
			fmt.aprintf("takes %d parameters", signature.param_count),
			"the fragment stage receives what the vertex stage returned",
			"write `fragment_main :: proc(v: Varying) -> [4]f32`",
		)
	} else if module.varying != nil && module.varying.name != "" {
		name := type_key(node_text(module.parsed, signature.param_type))
		if name != module.varying.name {
			error(
				module,
				"MBS-E15",
				fmt.aprintf("`fragment_main` must take `%s`, the struct `vertex_main` returns", module.varying.name),
				signature.param_type,
				fmt.aprintf("found `%s`", name),
				"the fragment stage receives what the vertex stage returned",
				fmt.aprintf("write `fragment_main :: proc(v: %s) -> [4]f32`", module.varying.name),
			)
		}
	} else {
		resolve_struct(module, signature.param_type, "the parameter of `fragment_main`")
	}

	if signature.result_count != 1 || type_key(node_text(module.parsed, signature.result_type)) != "[4]f32" {
		node: ^ast.Node = signature.result_type
		if node == nil {
			node = entry.lit.type
		}
		error(
			module,
			"MBS-E15",
			"`fragment_main` must return `[4]f32`, the colour of the pixel",
			node,
			"wrong result",
			"the fragment stage writes one colour: red, green, blue and alpha",
			"write `fragment_main :: proc(v: Varying) -> [4]f32`",
		)
	}
}

// resolve_struct finds the struct a parameter or result names. A name that isn't a struct is MBS-E14.
@(private = "file")
resolve_struct :: proc(module: ^Module, type: ^ast.Expr, what: string) -> ^Struct_Info {
	if type == nil {
		return nil
	}
	identifier, is_ident := type.derived.(^ast.Ident)
	if is_ident == false {
		error(
			module,
			"MBS-E15",
			fmt.aprintf("%s must be a named struct", what),
			type,
			"not a struct name",
			"the entry points pass structs, so each field can be tagged with where it comes from or goes to",
			"declare the struct with `Name :: struct { ... }` and use its name",
		)
		return nil
	}

	found := find_struct(module, identifier.name)
	if found != nil {
		return found
	}

	names := make([dynamic]string)
	for info in module.structs {
		append(&names, info.name)
	}
	help := "declare it with `Name :: struct { ... }`"
	if suggestion, close := suggest_name(identifier.name, names[:]); close {
		help = fmt.aprintf("did you mean `%s`?", suggestion)
	}
	error(
		module,
		"MBS-E14",
		fmt.aprintf("cannot find the struct `%s` in this shader", identifier.name),
		type,
		"not found",
		"the shader doesn't declare a struct with this name",
		help,
	)
	return nil
}

// Every field of the vertex input says which attribute it reads.
@(private = "file")
check_vertex_input :: proc(module: ^Module, info: ^Struct_Info) {
	for field in info.fields {
		if field.out != "" {
			error(
				module,
				"MBS-E24",
				"`out:` is for the vertex output, not the vertex input",
				field.node,
				"misplaced tag",
				"the vertex input says what it reads with `attr:\"...\"`",
				fmt.aprintf("write `attr:\"%s\"`", field.name),
			)
		}
		if field.attr == "" {
			error(
				module,
				"MBS-E15",
				fmt.aprintf("the vertex input field `%s` has no `attr:` tag", field.name),
				field.name_node,
				"which attribute does this read?",
				"each field of the vertex input is one attribute of the mesh, named by its tag",
				fmt.aprintf("write `%s: %s `attr:\"%s\"``", field.name, field.type_text, guess_attribute(field.name)),
			)
			continue
		}
		check_tag_value(module, field, "attr", field.attr, VERTEX_ATTRIBUTES[:], "attribute")
	}
}

// The vertex output has exactly one `out:"position"`, and every tag is a name the targets can carry.
@(private = "file")
check_varying :: proc(module: ^Module, info: ^Struct_Info) {
	position_count := 0
	seen := make(map[string]string)
	for field in info.fields {
		if field.attr != "" {
			error(
				module,
				"MBS-E24",
				"`attr:` is for the vertex input, not the vertex output",
				field.node,
				"misplaced tag",
				"the vertex output says where a value goes with `out:\"...\"`",
				fmt.aprintf("write `out:\"%s\"`", VARYING_OUTPUTS[0]),
			)
		}
		if field.out == "" {
			if module.target == .PICA200 {
				error(
					module,
					"MBS-E6",
					fmt.aprintf("`%s` has no hardware output on the 3DS", field.name),
					field.name_node,
					"a varying with no tag",
					"the PICA200 passes only position, colour and up to three texture coordinates from the vertex stage to the fragment stage",
					fmt.aprintf("tag it `out:\"texcoord0\"` (to `\"texcoord2\"`) or `out:\"color\"`, or remove it and compute it in `fragment_main`"),
				)
			}
			continue
		}
		check_tag_value(module, field, "out", field.out, VARYING_OUTPUTS[:], "output")

		if earlier, used := seen[field.out]; used {
			error(
				module,
				"MBS-E25",
				fmt.aprintf("two fields write `%s`", field.out),
				field.name_node,
				fmt.aprintf("`%s` already does", earlier),
				"each output of the vertex stage holds one value",
				"give the second field a different output, or remove it",
			)
		}
		seen[field.out] = field.name

		if field.out == "position" {
			position_count += 1
			if type_key(field.type_text) != "[4]f32" {
				error(
					module,
					"MBS-E15",
					"the position output must be `[4]f32`",
					field.type,
					fmt.aprintf("found `%s`", type_key(field.type_text)),
					"the position is the clip-space position: x, y, z and w",
					fmt.aprintf("write `%s: [4]f32 `out:\"position\"``", field.name),
				)
			}
		}
	}

	if position_count == 0 {
		error(
			module,
			"MBS-E15",
			fmt.aprintf("`%s` has no `out:\"position\"` field", info.name if info.name != "" else "the vertex output"),
			info.node,
			"which field is the position?",
			"the vertex stage must write the clip-space position, and one field says so with the tag `out:\"position\"`",
			"add `position: [4]f32 `out:\"position\"``",
		)
	}
}

// check_tag_value reports a tag value the engine doesn't know, with a suggestion when it is close to one.
@(private = "file")
check_tag_value :: proc(module: ^Module, field: Field_Info, key, value: string, allowed: []string, what: string) {
	for name in allowed {
		if name == value {
			return
		}
	}
	help := fmt.aprintf("the %ss are: %s", what, strings.join(allowed, ", "))
	if suggestion, close := suggest_name(value, allowed); close {
		help = fmt.aprintf("did you mean `%s`?", suggestion)
	}
	error(
		module,
		"MBS-E24",
		fmt.aprintf("`%s` is not a known %s", value, what),
		field.node,
		fmt.aprintf("unknown value in `%s:\"%s\"`", key, value),
		fmt.aprintf("the %ss a shader can use are: %s", what, strings.join(allowed, ", ")),
		help,
	)
}

// guess_attribute suggests an attribute for a field: its own name when that is an attribute, else the first one.
@(private = "file")
guess_attribute :: proc(field_name: string) -> string {
	for name in VERTEX_ATTRIBUTES {
		if name == field_name {
			return name
		}
	}
	return VERTEX_ATTRIBUTES[0]
}
