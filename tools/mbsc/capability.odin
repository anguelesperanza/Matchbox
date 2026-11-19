package mbsc

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// What the target can do (S7). The type checker (check.odin) finds out what a shader does and notes the operations
// some targets can't do; this pass reads those notes for the target being built, and reports:
//
//   MBS-E1   a built-in or a matrix product the 3DS vertex unit doesn't have
//   MBS-E2   a built-in the 3DS fragment stage can't do (the rest of E2 comes with the fragment plan, S6)
//   MBS-E4   more uniform registers than the 3DS has
//   MBS-E6   a varying with no hardware output on the 3DS (found in entry.odin)
//   MBS-E8   a texture sample in the 3DS vertex stage
//   MBS-E9   whole-number arithmetic in the 3DS vertex stage
//   MBS-E10  an index that isn't a constant or a loop counter, on the 3DS
//   MBS-E11  a condition with more than two comparisons, on the 3DS
//   MBS-E12  a `discard()` that isn't the alpha test, on the 3DS
//   MBS-E19  more than 3 textures sampled in a 3DS fragment shader
//   MBS-E20  a texture coordinate that isn't a plain `texcoord` varying, on the 3DS
//   MBS-E28  something the PC backend can't write (HLSL), or a struct uniform written inline
//
// Not here, because they depend on what a backend makes of the shader: E3 and E5 (stages and registers used), E21
// and the rest of E2 (the fragment plan). They come with S5 and S6.

// Use_Kind is an operation the type checker notes while it reads a procedure.
Use_Kind :: enum {
	MATRIX_PRODUCT, // matrix times matrix
	INT_ARITHMETIC, // + - * / with a whole number
	DYNAMIC_INDEX, // an index that is neither a constant nor a loop counter
	CONDITION, // an `if` condition; `count` is how many comparisons it holds
	ARRAY_LITERAL_ARGUMENT, // `f([3]f32{...})`
	UNIFORM_READ, // a uniform's name; `name` says which
}

Use :: struct {
	kind:      Use_Kind,
	proc_name: string,
	node:      ^ast.Node,
	count:     int,
	name:      string,
}

THREE_DS_FLOAT_REGISTERS :: 96
THREE_DS_TEXTURES :: 3
THREE_DS_CONDITIONS :: 2

// check_target reports what the shader does that the target can't. Call it after the type checker.
check_target :: proc(module: ^Module) {
	if module.vertex_main == nil || module.fragment_main == nil {
		return
	}
	vertex := reachable(module, module.vertex_main.name)
	fragment := reachable(module, module.fragment_main.name)

	#partial switch module.target {
	case .PC:
		check_pc(module, vertex, fragment)
	case .PICA200:
		check_3ds_vertex(module, vertex)
		check_3ds_fragment(module, fragment)
	}
}

// check_declarations is for what a declaration can't do on any target. Call it once the declarations are read.
check_declarations :: proc(module: ^Module) {
	for uniform in module.uniforms {
		if uniform.kind == .GAME && uniform.block != nil && uniform.block.name == "" {
			error(
				module,
				"MBS-E28",
				fmt.aprintf("the uniform `%s` is a struct written inline", uniform.name),
				uniform.node,
				"declare the struct first",
				"the game sets a struct uniform by naming its fields, and the targets need the struct's name to lay it out",
				fmt.aprintf("write `Name :: struct {{ ... }}` once, then `@(uniform) %s: Name`", uniform.name),
			)
		}
	}
}

// reachable is the names of the procedures an entry point runs, itself included.
@(private = "file")
reachable :: proc(module: ^Module, entry: string) -> map[string]bool {
	seen := make(map[string]bool, context.temp_allocator)
	pending := make([dynamic]string, context.temp_allocator)
	append(&pending, entry)
	for len(pending) > 0 {
		name := pop(&pending)
		if seen[name] {
			continue
		}
		seen[name] = true
		for edge in module.edges {
			if edge.caller == name && edge.builtin == false {
				append(&pending, edge.callee)
			}
		}
	}
	return seen
}

@(private = "file")
stage_word :: proc(module: ^Module, caller: string) -> string {
	if caller == module.vertex_main.name {
		return "it is used in `vertex_main`"
	}
	return fmt.aprintf("it is used in `%s`, which `vertex_main` calls", caller)
}

// ---- PC ---------------------------------------------------------------------------------------------------

@(private = "file")
check_pc :: proc(module: ^Module, vertex, fragment: map[string]bool) {
	// HLSL can't return an array, and can't take an array written out as an argument
	for info in module.procs {
		if (vertex[info.name] || fragment[info.name]) == false {
			continue
		}
		signature := module.signatures[info.name]
		if signature.result != nil && signature.result.kind == .ARRAY {
			error(
				module,
				"MBS-E28",
				fmt.aprintf("`%s` returns an array, which the PC backend can't write", info.name),
				info.node,
				"returns an array",
				"HLSL has no array result, so the generated shader would not compile",
				"return a struct that holds the values, or fill an array the caller declared",
			)
		}
	}
	for use in module.uses {
		if use.kind == .ARRAY_LITERAL_ARGUMENT && (vertex[use.proc_name] || fragment[use.proc_name]) {
			error(
				module,
				"MBS-E28",
				"an array written out can't be passed to a procedure on the PC",
				use.node,
				"array written as an argument",
				"HLSL accepts an array literal only as the start of a variable",
				"put it in a variable first: `values := [3]f32{...}`, then pass `values`",
			)
		}
	}

	// HLSL samples differently in the two stages (the vertex stage has no derivatives)
	reported := make(map[rawptr]bool, context.temp_allocator)
	for edge in module.edges {
		if edge.builtin && edge.callee == "sample" && vertex[edge.caller] && fragment[edge.caller] && reported[edge.node] == false {
			reported[edge.node] = true
			error(
				module,
				"MBS-E28",
				fmt.aprintf("`%s` samples a texture and runs in both stages", edge.caller),
				edge.node,
				"sampled in both stages",
				"HLSL's `sample` needs a mip level chosen in the vertex stage and derivatives in the fragment stage, so one copy can't serve both",
				"write one procedure for each stage, or sample in the fragment stage and pass the colour through a varying",
			)
		}
	}
}

// ---- 3DS vertex -------------------------------------------------------------------------------------------

// What the 3DS vertex unit has no instruction for, and what to write instead (section 14 of the language reference).
@(private = "file")
Missing :: struct {
	name: string,
	help: string,
}

@(rodata, private = "file")
THREE_DS_MISSING := [?]Missing {
	{"sin", "use `sin_approx(x)`, which states its error"},
	{"cos", "use `cos_approx(x)`, which states its error"},
	{"tan", "write `sin_approx(x) / cos_approx(x)`, keeping `cos_approx` away from zero"},
	{"asin", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"acos", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"atan", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"atan2", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"sinh", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"cosh", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"tanh", "work it out on the CPU and pass the result as a uniform, or give the 3DS its own version with `when TARGET == .PICA200`"},
	{"ldexp", "write `x * exp2(e)`"},
	{"is_nan", "the 3DS has no equivalent; leave the check out on the 3DS with `when TARGET != .PICA200`"},
	{"is_inf", "the 3DS has no equivalent; leave the check out on the 3DS with `when TARGET != .PICA200`"},
	{"transpose", "do it on the CPU and pass the result as a uniform"},
	{"determinant", "do it on the CPU and pass the result as a uniform"},
}

@(private = "file")
find_missing :: proc(name: string) -> (found: Missing, ok: bool) {
	for missing in THREE_DS_MISSING {
		if missing.name == name {
			return missing, true
		}
	}
	return {}, false
}

@(private = "file")
check_3ds_vertex :: proc(module: ^Module, vertex: map[string]bool) {
	reported := make(map[rawptr]bool, context.temp_allocator)

	for edge in module.edges {
		if edge.builtin == false || vertex[edge.caller] == false || reported[edge.node] {
			continue
		}
		if edge.callee == "sample" || edge.callee == "sample_lod" {
			reported[edge.node] = true
			error(
				module,
				"MBS-E8",
				fmt.aprintf("`%s` reads a texture in a vertex shader, which the 3DS can't do", edge.callee),
				edge.node,
				"texture read in the vertex stage",
				fmt.aprintf("%s, and the PICA200 vertex unit can't read textures", stage_word(module, edge.caller)),
				"sample in `fragment_main`, pass the data in a uniform, or put the lookup in a `when TARGET != .PICA200` branch",
			)
			continue
		}
		if missing, found := find_missing(edge.callee); found {
			reported[edge.node] = true
			error(
				module,
				"MBS-E1",
				fmt.aprintf("`%s` is not available in 3DS vertex shaders", edge.callee),
				edge.node,
				"no instruction for this on the target",
				fmt.aprintf("%s; the PICA200 vertex unit has no instruction for it, and mbsc doesn't swap in a close one", stage_word(module, edge.caller)),
				missing.help,
			)
		}
	}

	conditions_reported := make(map[rawptr]bool, context.temp_allocator)
	for use in module.uses {
		if vertex[use.proc_name] == false || conditions_reported[use.node] {
			continue
		}
		#partial switch use.kind {
		case .MATRIX_PRODUCT:
			conditions_reported[use.node] = true
			error(
				module,
				"MBS-E1",
				"a matrix times a matrix is not available in 3DS vertex shaders",
				use.node,
				"matrix times matrix",
				"the PICA200 multiplies a matrix by a vector, one `dp4` per row, and has no instruction for two matrices",
				"multiply them on the CPU and pass the result as a uniform",
			)
		case .INT_ARITHMETIC:
			conditions_reported[use.node] = true
			error(
				module,
				"MBS-E9",
				"whole-number arithmetic is not available in 3DS vertex shaders",
				use.node,
				"arithmetic on whole numbers",
				"the PICA200 vertex unit has no integer ALU; a whole number is only a loop counter or an index",
				"use `f32`, or keep the number as a loop counter and index only",
			)
		case .DYNAMIC_INDEX:
			conditions_reported[use.node] = true
			error(
				module,
				"MBS-E10",
				"this index is not a constant or a loop counter",
				use.node,
				"not known when the shader is built",
				"the PICA200 can index with a constant, a `for` counter or one of two address registers, nothing computed",
				"loop over the array with `for i in 0..<N`, or index with a constant",
			)
		case .CONDITION:
			if use.count > THREE_DS_CONDITIONS {
				conditions_reported[use.node] = true
				error(
					module,
					"MBS-E11",
					fmt.aprintf("this condition has %d comparisons; the 3DS can hold %d", use.count, THREE_DS_CONDITIONS),
					use.node,
					"too many comparisons",
					"the PICA200 has two condition flags (`cmp.x` and `cmp.y`), set by one comparison, and a condition can combine those two",
					"nest `if`s, or use `lerp` and `step` for a result with no branch",
				)
			}
		}
	}

	check_uniform_registers(module, vertex)
}

// registers is how many float vector registers a uniform of this type takes on the 3DS.
@(private = "file")
registers :: proc(module: ^Module, type: ^Type) -> int {
	#partial switch type.kind {
	case .F32:
		return 1
	case .VECTOR:
		return 1 if type.elem.kind == .F32 else 0
	case .MATRIX:
		return type.rows
	case .ARRAY:
		return type.count * registers(module, type.elem)
	case .STRUCT:
		total := 0
		for field_type in module.struct_fields[type.info] {
			total += registers(module, field_type)
		}
		return total
	}
	return 0 // whole numbers and booleans live in their own registers
}

@(private = "file")
check_uniform_registers :: proc(module: ^Module, vertex: map[string]bool) {
	Counted :: struct {
		name:      string,
		registers: int,
		node:      ^ast.Node,
	}
	used := make(map[string]bool, context.temp_allocator)
	for use in module.uses {
		if use.kind == .UNIFORM_READ && vertex[use.proc_name] {
			used[use.name] = true
		}
	}
	counted := make([dynamic]Counted, context.temp_allocator)
	total := 0
	for uniform in module.uniforms {
		if used[uniform.name] == false {
			continue
		}
		type := module.uniform_types[uniform.name]
		if type == nil {
			continue
		}
		count := registers(module, type)
		total += count
		append(&counted, Counted{uniform.name, count, uniform.node})
	}
	if total <= THREE_DS_FLOAT_REGISTERS {
		return
	}

	slice.stable_sort_by(counted[:], proc(a, b: Counted) -> bool {
		return a.registers > b.registers
	})
	parts := make([dynamic]string, context.temp_allocator)
	for entry in counted {
		append(&parts, fmt.aprintf("`%s` uses %d", entry.name, entry.registers))
	}
	error(
		module,
		"MBS-E4",
		fmt.aprintf("this shader uses %d uniform registers; the 3DS has %d", total, THREE_DS_FLOAT_REGISTERS),
		counted[0].node,
		fmt.aprintf("the largest, %d registers", counted[0].registers),
		fmt.aprintf("a `matrix[4, 4]f32` takes 4, a `[4]f32` takes 1 and an `f32` takes 1; %s", strings.join(parts[:], ", ", context.temp_allocator)),
		fmt.aprintf("`%s` is the largest; lower its length, or compute part of it on the CPU", counted[0].name),
	)
}

// ---- 3DS fragment -----------------------------------------------------------------------------------------

// The built-ins a TexEnv stage has a mode for. The shapes they may take are the fragment plan's business (S6).
@(rodata, private = "file")
THREE_DS_FRAGMENT_BUILTINS := [?]string{"sample", "lerp", "saturate", "dot3_signed", "discard"}

@(private = "file")
check_3ds_fragment :: proc(module: ^Module, fragment: map[string]bool) {
	reported := make(map[rawptr]bool, context.temp_allocator)
	sampled := make(map[string]bool, context.temp_allocator)

	for edge in module.edges {
		if edge.builtin == false || fragment[edge.caller] == false || reported[edge.node] {
			continue
		}
		if slice.contains(THREE_DS_FRAGMENT_BUILTINS[:], edge.callee) == false {
			reported[edge.node] = true
			help := "do the work in the vertex stage and pass the result as `color`, or give the 3DS its own version: `when TARGET == .PICA200 { ... }`"
			if missing, found := find_missing(edge.callee); found {
				help = missing.help
			}
			error(
				module,
				"MBS-E2",
				fmt.aprintf("`%s` can't run in a 3DS fragment shader", edge.callee),
				edge.node,
				"not a texture combiner operation",
				"the 3DS has no pixel shader; its fragment stage is up to 6 fixed combiner stages, each REPLACE, MODULATE, ADD, ADD_SIGNED, INTERPOLATE, SUBTRACT, DOT3_RGB, DOT3_RGBA, MULTIPLY_ADD or ADD_MULTIPLY",
				help,
			)
			continue
		}
		if edge.callee == "sample" {
			check_texture_coordinate(module, edge, &sampled, &reported)
		}
	}

	check_discards(module, fragment)
}

// A sample reads a texture of its own, and its coordinate comes straight from a `texcoord` output of the vertex stage.
@(private = "file")
check_texture_coordinate :: proc(module: ^Module, edge: Call_Edge, sampled: ^map[string]bool, reported: ^map[rawptr]bool) {
	call, is_call := edge.node.derived.(^ast.Call_Expr)
	if is_call == false || len(call.args) != 2 {
		return
	}
	if texture, is_ident := call.args[0].derived.(^ast.Ident); is_ident {
		if sampled[texture.name] == false {
			sampled[texture.name] = true
			if len(sampled) > THREE_DS_TEXTURES {
				error(
					module,
					"MBS-E19",
					fmt.aprintf("this fragment shader samples %d textures; the 3DS has %d texture units", len(sampled), THREE_DS_TEXTURES),
					call.args[0],
					fmt.aprintf("texture %d", len(sampled)),
					"each texture takes one of TEXTURE0, TEXTURE1 and TEXTURE2",
					"combine textures into one before the game uses them (the sprite packer can bake this)",
				)
			}
		}
	}

	// the coordinate is checked where the sample is written in `fragment_main`; a helper gets its coordinate from
	// its caller, and the fragment plan (S6) follows it there
	if edge.caller != module.fragment_main.name {
		return
	}
	if plain_texcoord(module, call.args[1]) == false {
		error(
			module,
			"MBS-E20",
			"this texture coordinate is not a plain `texcoord` varying",
			call.args[1],
			"computed, or not a texcoord",
			"the 3DS reads a texture with the coordinate the vertex stage wrote to `texcoord0`, `texcoord1` or `texcoord2`, unchanged",
			"do the arithmetic on the coordinate in `vertex_main` and pass the result as a `texcoord`",
		)
	}
}

// plain_texcoord is true for `v.uv`, where `v` is the fragment stage's input and `uv` is tagged `out:"texcoord0"` to `"texcoord2"`.
@(private = "file")
plain_texcoord :: proc(module: ^Module, expr: ^ast.Expr) -> bool {
	selector, is_selector := expr.derived.(^ast.Selector_Expr)
	if is_selector == false || selector.field == nil {
		return false
	}
	base, is_ident := selector.expr.derived.(^ast.Ident)
	if is_ident == false {
		return false
	}
	symbol, found := module.symbols[base]
	if found == false || symbol.kind != .PARAM || module.varying == nil {
		return false
	}
	for field in module.varying.fields {
		if field.name == selector.field.name {
			return field.out == "texcoord0" || field.out == "texcoord1" || field.out == "texcoord2"
		}
	}
	return false
}

// ---- the alpha test -----------------------------------------------------------------------------------------

// settled_statements are the statements of a block with each `when` replaced by the branch the target takes.
@(private = "file")
settled_statements :: proc(module: ^Module, statements: []^ast.Stmt, into: ^[dynamic]^ast.Stmt) {
	for statement in statements {
		if when_statement, is_when := statement.derived.(^ast.When_Stmt); is_when {
			value, ok := eval_when(module, when_statement.cond)
			if ok {
				branch := when_statement.body if value else when_statement.else_stmt
				if block, is_block := branch.derived.(^ast.Block_Stmt); is_block {
					settled_statements(module, block.stmts, into)
				} else if branch != nil {
					append(into, branch)
				}
			}
			continue
		}
		append(into, statement)
	}
}

// the_discard_call finds `discard()` in an `if` body: `{ discard() }` or `do discard()`.
@(private = "file")
the_discard_call :: proc(body: ^ast.Stmt) -> ^ast.Call_Expr {
	if body == nil {
		return nil
	}
	statement := body
	if block, is_block := body.derived.(^ast.Block_Stmt); is_block {
		if len(block.stmts) != 1 {
			return nil
		}
		statement = block.stmts[0]
	}
	expression, is_expression := statement.derived.(^ast.Expr_Stmt)
	if is_expression == false {
		return nil
	}
	call, is_call := expression.expr.derived.(^ast.Call_Expr)
	if is_call == false {
		return nil
	}
	if callee, is_ident := call.expr.derived.(^ast.Ident); is_ident && callee.name == "discard" {
		return call
	}
	return nil
}

// a_reference is a number or an `f32` uniform: what the alpha test compares with.
@(private = "file")
a_reference :: proc(module: ^Module, expr: ^ast.Expr) -> bool {
	#partial switch node in expr.derived {
	case ^ast.Basic_Lit:
		return true
	case ^ast.Paren_Expr:
		return a_reference(module, node.expr)
	case ^ast.Unary_Expr:
		return a_reference(module, node.expr)
	case ^ast.Ident:
		symbol, found := module.symbols[node]
		return found && (symbol.kind == .UNIFORM || symbol.kind == .CONSTANT)
	case ^ast.Selector_Expr:
		if base, is_ident := node.expr.derived.(^ast.Ident); is_ident {
			symbol, found := module.symbols[base]
			return found && symbol.kind == .UNIFORM
		}
	}
	return false
}

// is_alpha_test recognises `if color.a < reference { discard() }` straight before `return color`.
@(private = "file")
is_alpha_test :: proc(module: ^Module, statements: []^ast.Stmt) -> ^ast.Call_Expr {
	if len(statements) < 2 {
		return nil
	}
	returned, is_return := statements[len(statements) - 1].derived.(^ast.Return_Stmt)
	if is_return == false || len(returned.results) != 1 {
		return nil
	}
	result, is_ident := returned.results[0].derived.(^ast.Ident)
	if is_ident == false {
		return nil
	}
	test, is_if := statements[len(statements) - 2].derived.(^ast.If_Stmt)
	if is_if == false || test.else_stmt != nil || test.init != nil {
		return nil
	}
	call := the_discard_call(test.body)
	if call == nil {
		return nil
	}
	comparison, is_comparison := test.cond.derived.(^ast.Binary_Expr)
	if is_comparison == false {
		return nil
	}
	#partial switch comparison.op.kind {
	case .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Cmp_Eq, .Not_Eq:
	case:
		return nil
	}
	alpha, is_selector := comparison.left.derived.(^ast.Selector_Expr)
	if is_selector == false || alpha.field == nil || (alpha.field.name != "a" && alpha.field.name != "w") {
		return nil
	}
	base, base_is_ident := alpha.expr.derived.(^ast.Ident)
	if base_is_ident == false || base.name != result.name || a_reference(module, comparison.right) == false {
		return nil
	}
	return call
}

@(private = "file")
check_discards :: proc(module: ^Module, fragment: map[string]bool) {
	statements := make([dynamic]^ast.Stmt, context.temp_allocator)
	if module.fragment_main.lit.body != nil {
		if block, is_block := module.fragment_main.lit.body.derived.(^ast.Block_Stmt); is_block {
			settled_statements(module, block.stmts, &statements)
		}
	}
	allowed := is_alpha_test(module, statements[:])

	reported := make(map[rawptr]bool, context.temp_allocator)
	for edge in module.edges {
		if edge.builtin == false || edge.callee != "discard" || fragment[edge.caller] == false || reported[edge.node] {
			continue
		}
		if allowed != nil && edge.node == &allowed.node {
			continue
		}
		reported[edge.node] = true
		error(
			module,
			"MBS-E12",
			"this `discard` isn't an alpha test",
			edge.node,
			"not an alpha test",
			"on the 3DS `discard` is the hardware alpha test: one comparison of the returned colour's alpha with one reference, as the last statement before `return`",
			"write `if color.a < reference { discard() }` straight before `return color`, with a number or an `f32` uniform as the reference",
		)
	}
}
