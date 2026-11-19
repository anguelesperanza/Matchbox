package mbsc

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// A Module is what a shader declares: its structs, uniforms, textures, procedures and constants, for one target.
// Step 3 of S1 builds it and checks the declarations; the type checker (step 4) works on it.

Tag :: struct {
	key:   string,
	value: string,
}

Field_Info :: struct {
	name:      string,
	type:      ^ast.Expr,
	type_text: string, // as written
	attr:      string, // the `attr:"..."` tag, "" when there is none
	out:       string, // the `out:"..."` tag, "" when there is none
	node:      ^ast.Node, // for messages
	name_node: ^ast.Node,
}

Struct_Info :: struct {
	name:   string, // "" for a struct written inline
	fields: []Field_Info,
	node:   ^ast.Node,
}

Uniform_Kind :: enum {
	FRAME, // the engine's per-frame block
	DRAW, // the engine's per-draw block
	GAME, // one the game sets by name
}

Uniform_Info :: struct {
	name:      string,
	kind:      Uniform_Kind,
	type:      ^ast.Expr,
	type_text: string,
	block:     ^Struct_Info, // the fields, when the type is a struct (written inline or named); else nil
	node:      ^ast.Node,
}

Texture_Info :: struct {
	name: string,
	slot: int,
	node: ^ast.Node,
}

Proc_Info :: struct {
	name: string,
	lit:  ^ast.Proc_Lit,
	node: ^ast.Node,
}

Constant_Info :: struct {
	name:  string,
	value: ^ast.Expr,
	node:  ^ast.Node,
}

Module :: struct {
	parsed:        ^Parsed,
	target:        Target,
	structs:       [dynamic]^Struct_Info,
	uniforms:      [dynamic]Uniform_Info,
	textures:      [dynamic]Texture_Info,
	procs:         [dynamic]Proc_Info,
	constants:     [dynamic]Constant_Info,
	vertex_in:     ^Struct_Info, // set when the entry points check out
	varying:       ^Struct_Info,
	vertex_main:   ^Proc_Info,
	fragment_main: ^Proc_Info,
	names:         map[string]^ast.Node, // everything declared at file level, for finding duplicates

	// Filled by the type checker (check.odin), for the intermediate form.
	types:         map[^ast.Expr]^Type, // the type of every expression
	symbols:       map[^ast.Ident]Symbol, // what every name refers to
	signatures:    map[string]Proc_Types, // parameter and result types of each procedure
	struct_fields: map[^Struct_Info][]^Type,
	uniform_types: map[string]^Type, // the type of each uniform, by name
	decl_types:    map[^ast.Value_Decl]^Type, // the type of each variable declared inside a procedure
	edges:         [dynamic]Call_Edge, // who calls whom, built-ins included
	uses:          [dynamic]Use, // the operations some targets can't do (capability.odin decides which)
}

// build_module reads the declarations of a parsed shader for one target and checks them. Problems are added to
// parsed.diagnostics. The module lives in the parsed shader's arena. Call it only for a file that parsed and
// stayed inside the subset.
build_module :: proc(parsed: ^Parsed, target: Target) -> ^Module {
	context.allocator = virtual.arena_allocator(&parsed.arena)

	module := new(Module)
	module.parsed = parsed
	module.target = target
	for name in PREDECLARED_NAMES {
		module.names[name] = nil
	}

	collect_statements(module, parsed.file.decls[:])
	check_engine_uniforms(module)
	check_declarations(module)
	check_texture_slots(module)
	check_entry_points(module)

	// The insides of the procedures are checked once the declarations are right, so one mistake in a
	// declaration doesn't also show up everywhere the name is used.
	if len(parsed.diagnostics) == 0 {
		check_bodies(module)
	}
	return module
}

find_struct :: proc(module: ^Module, name: string) -> ^Struct_Info {
	for info in module.structs {
		if info.name == name {
			return info
		}
	}
	return nil
}

find_proc :: proc(module: ^Module, name: string) -> ^Proc_Info {
	for &info in module.procs {
		if info.name == name {
			return &info
		}
	}
	return nil
}

// ---- reading the declarations -----------------------------------------------------------------------------

@(private = "file")
collect_statements :: proc(module: ^Module, statements: []^ast.Stmt) {
	for statement in statements {
		collect_statement(module, statement)
	}
}

@(private = "file")
collect_statement :: proc(module: ^Module, statement: ^ast.Stmt) {
	if statement == nil {
		return
	}
	#partial switch node in statement.derived {
	case ^ast.Value_Decl:
		collect_declaration(module, node)
	case ^ast.When_Stmt:
		value, ok := eval_when(module, node.cond)
		if ok == false {
			return
		}
		chosen := node.body if value else node.else_stmt
		collect_branch(module, chosen)
	case ^ast.Block_Stmt:
		collect_statements(module, node.stmts)
	}
}

@(private = "file")
collect_branch :: proc(module: ^Module, branch: ^ast.Stmt) {
	if branch == nil {
		return
	}
	#partial switch node in branch.derived {
	case ^ast.Block_Stmt:
		collect_statements(module, node.stmts)
	case:
		collect_statement(module, branch)
	}
}

@(private = "file")
collect_declaration :: proc(module: ^Module, decl: ^ast.Value_Decl) {
	if len(decl.names) != 1 {
		return
	}
	name_ident, is_ident := decl.names[0].derived.(^ast.Ident)
	if is_ident == false {
		return
	}
	name := name_ident.name

	if previous, taken := module.names[name]; taken {
		first := "built into the shader language" if previous == nil else "declared earlier in this file"
		error(
			module,
			"MBS-E25",
			fmt.aprintf("`%s` is declared twice", name),
			name_ident,
			"second declaration",
			fmt.aprintf("every name at the top level of a shader must be unique; `%s` is %s", name, first),
			"rename one of them",
		)
		return
	}
	module.names[name] = decl

	if decl.is_mutable == false {
		collect_constant_like(module, decl, name)
		return
	}
	collect_variable(module, decl, name, name_ident)
}

// `name :: value`: a struct, a procedure or a constant.
@(private = "file")
collect_constant_like :: proc(module: ^Module, decl: ^ast.Value_Decl, name: string) {
	if len(decl.attributes) > 0 {
		attribute_misuse(module, decl, "an attribute can only be put on a variable such as `name: type`, not on a `::` declaration")
	}
	if len(decl.values) != 1 {
		return
	}
	value := decl.values[0]
	#partial switch node in value.derived {
	case ^ast.Proc_Lit:
		append(&module.procs, Proc_Info{name = name, lit = node, node = decl})
	case ^ast.Struct_Type:
		info := read_struct(module, node, name)
		append(&module.structs, info)
	case:
		append(&module.constants, Constant_Info{name = name, value = value, node = decl})
	}
}

// `@(uniform) name: type` or `@(texture = N) name: Texture2D`.
@(private = "file")
collect_variable :: proc(module: ^Module, decl: ^ast.Value_Decl, name: string, name_ident: ^ast.Ident) {
	kind := Uniform_Kind.GAME
	is_uniform := false
	is_texture := false
	slot := 0

	for attribute in decl.attributes {
		for element in attribute.elems {
			attribute_name, value := split_attribute(element)
			switch attribute_name {
			case "uniform":
				is_uniform = true
				if value != nil {
					kind, _ = read_uniform_kind(module, value)
				}
			case "texture":
				is_texture = true
				if value == nil {
					attribute_misuse(module, element, "a texture needs its slot: `@(texture = 0)`")
				} else {
					slot, _ = read_slot(module, value)
				}
			case:
				suggestion, found := suggest_name(attribute_name, {"uniform", "texture"})
				help := "the attributes are `uniform` and `texture`"
				if found {
					help = fmt.aprintf("did you mean `%s`?", suggestion)
				}
				error(
					module,
					"MBS-E24",
					fmt.aprintf("unknown attribute `%s`", attribute_name),
					element,
					"not an attribute of the shader language",
					"a variable at the top level of a shader is a uniform or a texture",
					help,
				)
			}
		}
	}

	if is_uniform == false && is_texture == false {
		if len(decl.attributes) == 0 {
			error(
				module,
				"MBS-E24",
				fmt.aprintf("the variable `%s` is not a uniform or a texture", name),
				name_ident,
				"needs `@(uniform)` or `@(texture = N)`",
				"a shader has no global variables: anything at the top level that changes per draw is a uniform, and a texture is a texture",
				fmt.aprintf("write `@(uniform) %s: <type>`", name),
			)
		}
		return
	}
	if is_uniform && is_texture {
		attribute_misuse(module, decl, "a variable can't be both a uniform and a texture")
		return
	}
	if len(decl.values) > 0 {
		error(
			module,
			"MBS-E24",
			fmt.aprintf("`%s` can't be given a value in the shader", name),
			decl.values[0],
			"uniforms and textures are set by the game",
			"a uniform is read-only inside a shader, and the game provides its value",
			fmt.aprintf("declare it as `@(uniform) %s: <type>` with no value", name),
		)
		return
	}
	if decl.type == nil {
		return
	}

	if is_texture {
		text := type_key(node_text(module.parsed, decl.type))
		if text != "Texture2D" {
			error(
				module,
				"MBS-E13",
				fmt.aprintf("`%s` is a texture, so its type must be `Texture2D`", name),
				decl.type,
				fmt.aprintf("found `%s`", text),
				"textures are declared as `Texture2D`",
				fmt.aprintf("write `@(texture = %d) %s: Texture2D`", slot, name),
			)
		}
		append(&module.textures, Texture_Info{name = name, slot = slot, node = decl})
		return
	}

	info := Uniform_Info {
		name      = name,
		kind      = kind,
		type      = decl.type,
		type_text = node_text(module.parsed, decl.type),
		node      = decl,
	}
	#partial switch type_node in decl.type.derived {
	case ^ast.Struct_Type:
		info.block = read_struct(module, type_node, "")
	case ^ast.Ident:
		info.block = find_struct(module, type_node.name)
	}
	append(&module.uniforms, info)
}

// split_attribute separates `name = value` into its two sides. A bare `name` has no value.
@(private = "file")
split_attribute :: proc(element: ^ast.Expr) -> (name: string, value: ^ast.Expr) {
	#partial switch node in element.derived {
	case ^ast.Ident:
		return node.name, nil
	case ^ast.Field_Value:
		if field, is_ident := node.field.derived.(^ast.Ident); is_ident {
			return field.name, node.value
		}
	}
	return "", nil
}

@(private = "file")
read_uniform_kind :: proc(module: ^Module, value: ^ast.Expr) -> (kind: Uniform_Kind, ok: bool) {
	selector, is_selector := value.derived.(^ast.Implicit_Selector_Expr)
	if is_selector {
		switch selector.field.name {
		case "FRAME":
			return .FRAME, true
		case "DRAW":
			return .DRAW, true
		}
	}
	error(
		module,
		"MBS-E24",
		"unknown uniform block",
		value,
		"not `.FRAME` or `.DRAW`",
		"the engine provides two blocks: `.FRAME` (once per frame) and `.DRAW` (once per draw). A uniform of your own has no value: `@(uniform)`",
		"write `@(uniform = .FRAME)`, `@(uniform = .DRAW)` or `@(uniform)`",
	)
	return .GAME, false
}

@(private = "file")
read_slot :: proc(module: ^Module, value: ^ast.Expr) -> (slot: int, ok: bool) {
	literal, is_literal := value.derived.(^ast.Basic_Lit)
	if is_literal && literal.tok.kind == .Integer {
		number := 0
		valid := len(literal.tok.text) > 0
		for character in transmute([]u8)literal.tok.text {
			if character < '0' || character > '9' {
				valid = false
				break
			}
			number = number * 10 + int(character - '0')
		}
		if valid {
			return number, true
		}
	}
	error(
		module,
		"MBS-E24",
		"a texture slot is a whole number",
		value,
		"not a slot number",
		"the slot says which texture unit the texture is bound to",
		"write `@(texture = 0)`",
	)
	return 0, false
}

@(private = "file")
attribute_misuse :: proc(module: ^Module, node: ^ast.Node, note: string) {
	error(module, "MBS-E24", "this attribute can't be used here", node, "misplaced attribute", note, "")
}

// ---- structs and their tags -------------------------------------------------------------------------------

@(private = "file")
read_struct :: proc(module: ^Module, node: ^ast.Struct_Type, name: string) -> ^Struct_Info {
	info := new(Struct_Info)
	info.name = name
	info.node = node

	fields := make([dynamic]Field_Info)
	if node.fields != nil {
		for field in node.fields.list {
			tags, tags_ok := parse_tag(field.tag.text)
			if tags_ok == false {
				error(
					module,
					"MBS-E24",
					"this field tag can't be read",
					field.tag.pos,
					len(field.tag.text),
					"not in the form `key:\"value\"`",
					"a tag is one or more `key:\"value\"` pairs inside backticks",
					"write it like `attr:\"position\"`",
				)
			}
			attr, out := "", ""
			for tag in tags {
				switch tag.key {
				case "attr":
					attr = tag.value
				case "out":
					out = tag.value
				}
			}
			for field_name in field.names {
				identifier, is_ident := field_name.derived.(^ast.Ident)
				if is_ident == false {
					continue
				}
				append(
					&fields,
					Field_Info {
						name = identifier.name,
						type = field.type,
						type_text = node_text(module.parsed, field.type),
						attr = attr,
						out = out,
						node = field,
						name_node = identifier,
					},
				)
			}
		}
	}
	info.fields = fields[:]
	return info
}

// parse_tag reads a struct field tag such as `attr:"position"`. The text still has its backticks (or quotes).
parse_tag :: proc(raw: string) -> (tags: []Tag, ok: bool) {
	if len(raw) == 0 {
		return nil, true
	}
	text := raw
	if len(text) >= 2 && (text[0] == '`' || text[0] == '"') && text[len(text) - 1] == text[0] {
		text = text[1:len(text) - 1]
	}

	list := make([dynamic]Tag)
	index := 0
	for index < len(text) {
		for index < len(text) && text[index] == ' ' {
			index += 1
		}
		if index >= len(text) {
			break
		}
		key_start := index
		for index < len(text) && text[index] != ':' && text[index] != ' ' {
			index += 1
		}
		if index >= len(text) || text[index] != ':' || index == key_start {
			return list[:], false
		}
		key := text[key_start:index]
		index += 1
		if index >= len(text) || text[index] != '"' {
			return list[:], false
		}
		index += 1
		value_start := index
		for index < len(text) && text[index] != '"' {
			index += 1
		}
		if index >= len(text) {
			return list[:], false
		}
		append(&list, Tag{key = key, value = text[value_start:index]})
		index += 1
	}
	return list[:], true
}

// ---- engine uniforms and textures -------------------------------------------------------------------------

@(private = "file")
check_engine_uniforms :: proc(module: ^Module) {
	seen_frame, seen_draw := false, false
	for uniform in module.uniforms {
		if uniform.kind == .GAME {
			continue
		}
		block_name := "frame" if uniform.kind == .FRAME else "draw"
		if uniform.kind == .FRAME {
			if seen_frame {
				duplicate_block(module, uniform, ".FRAME")
			}
			seen_frame = true
		} else {
			if seen_draw {
				duplicate_block(module, uniform, ".DRAW")
			}
			seen_draw = true
		}

		if uniform.block == nil {
			error(
				module,
				"MBS-E13",
				fmt.aprintf("the engine's `%s` block must be a struct", block_name),
				uniform.type,
				"not a struct",
				"the engine fills it field by field",
				fmt.aprintf("write `@(uniform = .%s) %s: struct { ... }`", "FRAME" if uniform.kind == .FRAME else "DRAW", uniform.name),
			)
			continue
		}

		known: []Engine_Field = FRAME_FIELDS[:] if uniform.kind == .FRAME else DRAW_FIELDS[:]
		for field in uniform.block.fields {
			expected, found := find_engine_field(known, field.name)
			if found == false {
				names := make([dynamic]string)
				for engine_field in known {
					append(&names, engine_field.name)
				}
				note := fmt.aprintf("the engine's `%s` block has: %s", block_name, strings.join(names[:], ", "))
				help := "remove the field"
				if suggestion, close := suggest_name(field.name, names[:]); close {
					help = fmt.aprintf("did you mean `%s`?", suggestion)
				}
				error(module, "MBS-E18", fmt.aprintf("the engine's `%s` block has no field `%s`", block_name, field.name), field.name_node, "not a field of the engine's block", note, help)
				continue
			}
			if type_key(field.type_text) != expected.type {
				error(
					module,
					"MBS-E13",
					fmt.aprintf("`%s.%s` has the wrong type", block_name, field.name),
					field.type,
					fmt.aprintf("found `%s`", type_key(field.type_text)),
					fmt.aprintf("the engine fills `%s.%s` as `%s`", block_name, field.name, display_type(expected.type)),
					fmt.aprintf("write `%s: %s`", field.name, display_type(expected.type)),
				)
			}
		}
	}
}

@(private = "file")
find_engine_field :: proc(fields: []Engine_Field, name: string) -> (field: Engine_Field, found: bool) {
	for candidate in fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

@(private = "file")
duplicate_block :: proc(module: ^Module, uniform: Uniform_Info, block: string) {
	error(
		module,
		"MBS-E25",
		fmt.aprintf("the engine's `%s` block is declared twice", block),
		uniform.node,
		"second declaration",
		"the engine fills one block of each kind, and it may declare any subset of the fields",
		"merge the fields into the first declaration",
	)
}

@(private = "file")
check_texture_slots :: proc(module: ^Module) {
	for texture, index in module.textures {
		for earlier in module.textures[:index] {
			if earlier.slot == texture.slot {
				error(
					module,
					"MBS-E25",
					fmt.aprintf("texture slot %d is used twice", texture.slot),
					texture.node,
					fmt.aprintf("`%s` and `%s` share slot %d", earlier.name, texture.name, texture.slot),
					"a slot is one texture unit, and it holds one texture",
					"give each texture its own slot",
				)
				break
			}
		}
	}
}

// ---- `when` -----------------------------------------------------------------------------------------------

// eval_when decides a `when` condition for the target being built. The language allows only `TARGET`,
// `==`, `!=`, `&&`, `||` and `!`. A condition it can't decide is reported as MBS-E23 and gives ok = false.
eval_when :: proc(module: ^Module, condition: ^ast.Expr) -> (value: bool, ok: bool) {
	#partial switch node in condition.derived {
	case ^ast.Paren_Expr:
		return eval_when(module, node.expr)
	case ^ast.Unary_Expr:
		if node.op.kind == .Not {
			inner, inner_ok := eval_when(module, node.expr)
			return !inner, inner_ok
		}
	case ^ast.Binary_Expr:
		#partial switch node.op.kind {
		case .Cmp_And, .Cmp_Or:
			left, left_ok := eval_when(module, node.left)
			right, right_ok := eval_when(module, node.right)
			if left_ok == false || right_ok == false {
				return false, false
			}
			return (left && right) if node.op.kind == .Cmp_And else (left || right), true
		case .Cmp_Eq, .Not_Eq:
			matches, compared := compare_target(module, node)
			if compared == false {
				return false, false
			}
			return matches if node.op.kind == .Cmp_Eq else !matches, true
		}
	case ^ast.Ident:
		switch node.name {
		case "true":
			return true, true
		case "false":
			return false, true
		}
	}
	error(
		module,
		"MBS-E23",
		"this `when` condition can't be decided when mbsc runs",
		condition,
		"not a test of `TARGET`",
		"a `when` is settled before the shader is compiled, so it can only use `TARGET`, `==`, `!=`, `&&`, `||` and `!`",
		"write `when TARGET == .PICA200 { ... }`",
	)
	return false, false
}

// compare_target handles `TARGET == .NAME` in either order.
@(private = "file")
compare_target :: proc(module: ^Module, node: ^ast.Binary_Expr) -> (matches: bool, ok: bool) {
	target_side, name_side := node.left, node.right
	if identifier, is_ident := target_side.derived.(^ast.Ident); is_ident == false || identifier.name != "TARGET" {
		target_side, name_side = node.right, node.left
	}
	identifier, is_ident := target_side.derived.(^ast.Ident)
	selector, is_selector := name_side.derived.(^ast.Implicit_Selector_Expr)
	if is_ident == false || identifier.name != "TARGET" || is_selector == false {
		error(
			module,
			"MBS-E23",
			"this `when` condition can't be decided when mbsc runs",
			node,
			"not a comparison of `TARGET` with `.PC`, `.VITA` or `.PICA200`",
			"a `when` is settled before the shader is compiled, so it can only compare `TARGET` with a target name",
			"write `when TARGET == .PICA200 { ... }`",
		)
		return false, false
	}

	named, known := target_from_name(selector.field.name)
	if known == false {
		help := "the targets are `.PC`, `.VITA` and `.PICA200`"
		if suggestion, close := suggest_name(selector.field.name, {"PC", "VITA", "PICA200"}); close {
			help = fmt.aprintf("did you mean `.%s`?", suggestion)
		}
		error(
			module,
			"MBS-E23",
			fmt.aprintf("`.%s` is not a target", selector.field.name),
			selector,
			"unknown target",
			"`TARGET` is one of `.PC`, `.VITA` or `.PICA200`",
			help,
		)
		return false, false
	}
	return named == module.target, true
}

target_from_name :: proc(name: string) -> (target: Target, ok: bool) {
	switch name {
	case "PC":
		return .PC, true
	case "VITA":
		return .VITA, true
	case "PICA200":
		return .PICA200, true
	}
	return {}, false
}

// ---- helpers ----------------------------------------------------------------------------------------------

// node_text is the source text of a node, as the author wrote it.
node_text :: proc(parsed: ^Parsed, node: ^ast.Node) -> string {
	src := parsed.file.src
	if node == nil || node.pos.offset < 0 || node.end.offset > len(src) || node.end.offset < node.pos.offset {
		return ""
	}
	return src[node.pos.offset:node.end.offset]
}

// error adds a message that points at a node, covering the node's first line.
error :: proc {
	error_at_node,
	error_at_pos,
}

error_at_node :: proc(module: ^Module, code, title: string, node: ^ast.Node, label, note, help: string) {
	length := 1
	if node.end.line == node.pos.line && node.end.offset > node.pos.offset {
		length = node.end.offset - node.pos.offset
	}
	add_diagnostic(module.parsed, code, title, node.pos, length, label, note, help)
}

error_at_pos :: proc(module: ^Module, code, title: string, pos: tokenizer.Pos, length: int, label, note, help: string) {
	add_diagnostic(module.parsed, code, title, pos, length, label, note, help)
}
