package mbsc

import "core:fmt"
import "core:strings"

// Statements of the PICA backend: variables, branches, unrolled loops, inlined calls, and the entry point.

// ---- returns --------------------------------------------------------------------------------------------------

pica_contains_return :: proc(stmts: []^IR_Stmt) -> bool {
	for stmt in stmts {
		switch node in stmt.variant {
		case IR_Return:
			return true
		case IR_If:
			if pica_contains_return(node.then) || pica_contains_return(node.otherwise) {
				return true
			}
		case IR_For:
			if pica_contains_return(node.body) {
				return true
			}
		case IR_Block:
			if pica_contains_return(node.body) {
				return true
			}
		case IR_Declare, IR_Assign, IR_Eval:
		}
	}
	return false
}

// pica_returns_ok is true when every `return` is at the end of the procedure, or at the end of both branches of an `if`
// that ends it. That is what inlining can follow without jumps.
pica_returns_ok :: proc(stmts: []^IR_Stmt) -> bool {
	for stmt, index in stmts {
		last := index == len(stmts) - 1
		switch node in stmt.variant {
		case IR_Return:
			if last == false {
				return false
			}
		case IR_If:
			if pica_contains_return(node.then) || pica_contains_return(node.otherwise) {
				if last == false || pica_returns_ok(node.then) == false || pica_returns_ok(node.otherwise) == false {
					return false
				}
			}
		case IR_For:
			if pica_contains_return(node.body) {
				return false
			}
		case IR_Block:
			if pica_contains_return(node.body) {
				if last == false || pica_returns_ok(node.body) == false {
					return false
				}
			}
		case IR_Declare, IR_Assign, IR_Eval:
		}
	}
	return true
}

// pica_nested_return is true when a `return` sits inside an `if` or a block, so the value has to be put in registers
// chosen before the branch.
pica_nested_return :: proc(stmts: []^IR_Stmt) -> bool {
	for stmt in stmts {
		#partial switch node in stmt.variant {
		case IR_If:
			if pica_contains_return(node.then) || pica_contains_return(node.otherwise) {
				return true
			}
		case IR_Block:
			if pica_contains_return(node.body) {
				return true
			}
		}
	}
	return false
}

// ---- inlining -------------------------------------------------------------------------------------------------

// pica_inline writes a procedure's body in place, with its parameters standing for the arguments, and returns its value.
pica_inline :: proc(h: ^Pica, callee: ^IR_Proc, args: []Pica_Value) -> Pica_Value {
	if pica_returns_ok(callee.body) == false {
		pica_problem(h, fmt.aprintf("`%s` returns early; on the 3DS a `return` has to be the last thing a procedure does (or end both sides of a last `if`)", callee.name))
		return pica_zero_value(h, callee.result)
	}
	for param, index in callee.params {
		h.env[param] = args[index]
	}

	saved_ret, saved_has := h.ret, h.has_ret
	defer {
		h.ret, h.has_ret = saved_ret, saved_has
	}
	h.has_ret = false
	if callee.result.kind != .VOID && pica_nested_return(callee.body) {
		count := pica_registers_of(h, callee.result)
		lanes := pica_lanes_of(h, callee.result)
		h.ret = make(Pica_Value, count)
		for index in 0 ..< count {
			h.ret[index] = pica_temp_operand(h, lanes[index])
			h.ret[index].owned = false
		}
		h.has_ret = true
	}

	h.depth += 1
	result := pica_block(h, callee.body)
	h.depth -= 1
	if h.has_ret {
		return h.ret
	}
	if result == nil {
		return pica_zero_value(h, callee.result)
	}
	return result
}

// ---- statements -----------------------------------------------------------------------------------------------

// pica_block writes the statements of one block, in a scope of its own, and returns the value of a `return` at its end.
// The block's registers are let go of by whoever opened the scope.
pica_block :: proc(h: ^Pica, stmts: []^IR_Stmt) -> Pica_Value {
	result: Pica_Value
	for stmt in stmts {
		mark := pica_mark(h)
		value, returned := pica_stmt(h, stmt)
		if returned {
			result = value
			continue
		}
		pica_end_statement(h, mark)
	}
	return result
}

pica_scoped_block :: proc(h: ^Pica, stmts: []^IR_Stmt) -> Pica_Value {
	mark := pica_mark(h)
	result := pica_block(h, stmts)
	// a returned value may live in a variable of this block, so a scope that returns is let go of by the statement
	// that called the procedure
	if result == nil {
		pica_end_scope(h, mark)
	}
	return result
}

pica_stmt :: proc(h: ^Pica, stmt: ^IR_Stmt) -> (value: Pica_Value, returned: bool) {
	switch node in stmt.variant {
	case IR_Declare:
		initial: Pica_Value
		if node.init != nil {
			initial = pica_eval(h, node.init)
		} else {
			initial = pica_zero_value(h, node.var.type)
		}
		h.env[node.var] = pica_bind_value(h, initial, node.var.type)
	case IR_Assign:
		source := pica_eval(h, node.value)
		place, ok := pica_place(h, node.target)
		if ok {
			pica_store(h, place.regs, place.lanes_per, place.only, source)
		}
	case IR_If:
		pica_if(h, node)
		if pica_contains_return(node.then) || pica_contains_return(node.otherwise) {
			return nil, h.has_ret == false
		}
	case IR_For:
		pica_for(h, node)
	case IR_Return:
		if node.value == nil {
			return nil, true
		}
		result := pica_eval(h, node.value)
		if h.has_ret {
			pica_store(h, h.ret, pica_lanes_of(h, node.value.type), nil, result)
			return nil, true
		}
		return result, true
	case IR_Eval:
		pica_eval(h, node.call)
	case IR_Block:
		result := pica_scoped_block(h, node.body)
		if result != nil {
			return result, true
		}
	}
	return nil, false
}

Pica_Place :: struct {
	regs:      Pica_Value,
	lanes_per: []int,
	only:      []int, // the lanes of the register that are written, when it is not the whole of it
}

// pica_place finds the registers (and lanes) an assignment writes.
pica_place :: proc(h: ^Pica, e: ^IR_Expr) -> (place: Pica_Place, ok: bool) {
	#partial switch node in e.variant {
	case IR_Var_Ref:
		regs, found := h.env[node.var]
		if found == false {
			pica_problem(h, fmt.aprintf("`%s` is set before it is declared", node.var.name))
			return {}, false
		}
		return Pica_Place{regs = regs, lanes_per = pica_lanes_of(h, node.var.type)}, true
	case IR_Field:
		base := pica_place(h, node.base) or_return
		offset := 0
		fields := pica_fields_of(h, node.base.type)
		for index in 0 ..< node.index {
			offset += pica_registers_of(h, fields[index].type)
		}
		size := pica_registers_of(h, e.type)
		return Pica_Place{regs = base.regs[offset:offset + size], lanes_per = base.lanes_per[offset:offset + size]}, true
	case IR_Index:
		base := pica_place(h, node.base) or_return
		index, known := pica_const_int(h, node.index)
		if known == false {
			pica_problem(h, "an index the shader computes can't be written on the 3DS; use a constant or a `for` counter")
			return {}, false
		}
		#partial switch node.base.type.kind {
		case .ARRAY:
			size := pica_registers_of(h, node.base.type.elem)
			return Pica_Place{regs = base.regs[int(index) * size:int(index + 1) * size], lanes_per = base.lanes_per[int(index) * size:int(index + 1) * size]}, true
		case .VECTOR:
			lanes := make([]int, 1)
			lanes[0] = int(index)
			return Pica_Place{regs = base.regs, lanes_per = base.lanes_per, only = lanes}, true
		}
		pica_problem(h, "a row of a matrix can't be assigned on the 3DS")
		return {}, false
	case IR_Swizzle:
		base := pica_place(h, node.base) or_return
		lanes := make([]int, node.count)
		for lane in 0 ..< node.count {
			lanes[lane] = int(node.indices[lane])
		}
		return Pica_Place{regs = base.regs, lanes_per = base.lanes_per, only = lanes}, true
	}
	pica_problem(h, "this can't be assigned to on the 3DS")
	return {}, false
}

pica_if :: proc(h: ^Pica, node: IR_If) {
	if known, is_known := pica_const_bool(h, node.condition); is_known {
		branch := node.then if known else node.otherwise
		pica_scoped_block(h, branch)
		return
	}
	line, ok := pica_condition(h, node.condition)
	if ok == false {
		return
	}
	pica_emit_line(h, line, 0, 1)
	pica_scoped_block(h, node.then)
	if len(node.otherwise) > 0 {
		pica_emit_line(h, ".else", -1, 1)
		pica_scoped_block(h, node.otherwise)
	}
	pica_emit_line(h, ".end", -1, 0)
}

PICA_MAX_UNROLL :: 64

pica_for :: proc(h: ^Pica, node: IR_For) {
	from, from_known := pica_const_int(h, node.from)
	to, to_known := pica_const_int(h, node.to)
	if from_known == false || to_known == false {
		pica_problem(h, "a `for` loop on the 3DS needs bounds that are known when the shader is built")
		return
	}
	last := to if node.inclusive else to - 1
	if last - from + 1 > PICA_MAX_UNROLL {
		pica_problem(h, fmt.aprintf("a `for` loop of %d turns is too long to write out; the limit is %d", last - from + 1, PICA_MAX_UNROLL))
		return
	}
	for counter := from; counter <= last; counter += 1 {
		h.loops[node.var] = counter
		pica_scoped_block(h, node.body)
	}
	delete_key(&h.loops, node.var)
}

// ---- conditions -----------------------------------------------------------------------------------------------

@(rodata)
PICA_COMPARE := [Binary_Op]string {
	.ADD           = "",
	.SUB           = "",
	.MUL           = "",
	.DIV           = "",
	.LESS          = "lt",
	.GREATER       = "gt",
	.LESS_EQUAL    = "le",
	.GREATER_EQUAL = "ge",
	.EQUAL         = "eq",
	.NOT_EQUAL     = "ne",
	.AND           = "",
	.OR            = "",
}

pica_is_comparison :: proc(e: ^IR_Expr) -> (node: IR_Binary, ok: bool) {
	binary, is_binary := e.variant.(IR_Binary)
	if is_binary && PICA_COMPARE[binary.op] != "" {
		return binary, true
	}
	return {}, false
}

pica_inverted :: proc(op: string) -> string {
	switch op {
	case "lt":
		return "ge"
	case "gt":
		return "le"
	case "le":
		return "gt"
	case "ge":
		return "lt"
	case "eq":
		return "ne"
	}
	return "eq"
}

pica_flipped :: proc(op: string) -> string {
	switch op {
	case "lt":
		return "gt"
	case "gt":
		return "lt"
	case "le":
		return "ge"
	case "ge":
		return "le"
	}
	return op
}

// Pica_Test is one comparison of two numbers: `a op b`, with the operator already inverted when the condition was `!`.
Pica_Test :: struct {
	a, b: ^IR_Expr,
	op:   string,
}

// pica_test reads a comparison, or the `!` of one.
pica_test :: proc(h: ^Pica, e: ^IR_Expr) -> (test: Pica_Test, ok: bool) {
	if comparison, is_comparison := pica_is_comparison(e); is_comparison {
		if is_float_gen(comparison.left.type) == false || comparison.left.type.kind != .F32 {
			pica_problem(h, "the 3DS compares one `f32` with another; compare the components one at a time")
			return {}, false
		}
		return Pica_Test{comparison.left, comparison.right, PICA_COMPARE[comparison.op]}, true
	}
	if unary, is_unary := e.variant.(IR_Unary); is_unary && unary.op == .NOT {
		inner := pica_test(h, unary.operand) or_return
		inner.op = pica_inverted(inner.op)
		return inner, true
	}
	return {}, false
}

// pica_condition writes the comparison and returns the line that opens the `if`: `ifc cmp.x`, `ifc cmp.x && cmp.y`,
// or `ifu name` for a boolean uniform.
pica_condition :: proc(h: ^Pica, e: ^IR_Expr) -> (line: string, ok: bool) {
	if loc, is_uniform := pica_uniform_loc(h, e); is_uniform && loc.type.kind == .BOOL {
		name := pica_declare_uniform(h, loc.prefix, loc.type)
		return fmt.aprintf("ifu %s", name), true
	}
	if test, is_test := pica_test(h, e); is_test {
		a := pica_eval(h, test.a)[0]
		b := pica_eval(h, test.b)[0]
		pica_compare_one(h, a, b, test.op)
		return "ifc cmp.x", true
	}
	if binary, is_binary := e.variant.(IR_Binary); is_binary && (binary.op == .AND || binary.op == .OR) {
		first, first_ok := pica_test(h, binary.left)
		second, second_ok := pica_test(h, binary.right)
		if first_ok && second_ok {
			left := pica_temp_operand(h, 2)
			right := pica_temp_operand(h, 2)
			pica_store(h, Pica_Value{left}, nil, []int{0}, Pica_Value{pica_eval(h, first.a)[0]})
			pica_store(h, Pica_Value{left}, nil, []int{1}, Pica_Value{pica_eval(h, second.a)[0]})
			pica_store(h, Pica_Value{right}, nil, []int{0}, Pica_Value{pica_eval(h, first.b)[0]})
			pica_store(h, Pica_Value{right}, nil, []int{1}, Pica_Value{pica_eval(h, second.b)[0]})
			pica_emit_line(h, fmt.aprintf("cmp %s, %s, %s, %s", pica_source_text(left), first.op, second.op, pica_source_text(right)))
			h.count += 1
			pica_release(h, left)
			pica_release(h, right)
			return fmt.aprintf("ifc cmp.x %s cmp.y", "&&" if binary.op == .AND else "||"), true
		}
	}
	pica_problem(h, "this condition isn't written for the 3DS: use one comparison of two `f32`, two of them joined by `&&` or `||`, or a boolean uniform")
	return "", false
}

// pica_compare_one is `cmp a, op, op, b`, which sets both flags from the first component (the second is not read).
pica_compare_one :: proc(h: ^Pica, a, b: Pica_Operand, op: string) {
	x, y := a, b
	op := op
	if pica_reads_constant(y) {
		if pica_reads_constant(x) == false {
			x, y = y, x
			op = pica_flipped(op)
		} else {
			y = pica_to_temp(h, y, 1)
		}
	}
	if pica_reads_constant(x) && x.neg {
		x = pica_to_temp(h, x, 1)
	}
	if x.kind == .INPUT && y.kind == .INPUT && x.base != y.base {
		y = pica_to_temp(h, y, 1)
	}
	pica_emit_line(h, fmt.aprintf("cmp %s, %s, %s, %s", pica_source_text(x), op, op, pica_source_text(y)))
	h.count += 1
	pica_release(h, x)
	pica_release(h, y)
}

// ---- the entry point ------------------------------------------------------------------------------------------

generate_vertex :: proc(h: ^Pica) {
	entry := h.ir.vertex_main
	if entry == nil || len(entry.params) != 1 {
		pica_problem(h, "`vertex_main` must take one struct and return one")
		return
	}

	// the attributes arrive in v0, v1, ...: one register for each field of the input, in the order they are written
	input_fields := pica_fields_of(h, entry.params[0].type)
	input := make(Pica_Value, len(input_fields))
	for field, index in input_fields {
		if is_float_gen(field.type) == false {
			pica_problem(h, fmt.aprintf("the vertex input `%s` isn't an `f32` or a vector of them", field.name))
			continue
		}
		input[index] = Pica_Operand {
			kind = .INPUT,
			base = fmt.aprintf("v%d", index),
			swz  = pica_ident(component_count(field.type)),
			temp = -1,
		}
	}
	if len(input_fields) > 16 {
		pica_problem(h, "the vertex input has more than 16 attributes, which the 3DS can't take")
	}

	result := pica_inline_entry(h, entry, input)
	output_fields := pica_fields_of(h, entry.result)
	if len(result) != len(output_fields) {
		return
	}
	for field, index in output_fields {
		if field.out == "" {
			continue
		}
		name := strings.concatenate({"mbs_out_", field.out})
		fmt.sbprintfln(&h.outputs_text, ".out %s %s", name, field.out)
		lanes := component_count(field.type)
		if field.out == "position" {
			lanes = 4
		}
		pica_emit(h, "mov", name, pica_first_lanes(lanes), result[index])
	}
}

// pica_inline_entry is pica_inline for the entry point: its one parameter is the input.
pica_inline_entry :: proc(h: ^Pica, entry: ^IR_Proc, input: Pica_Value) -> Pica_Value {
	args := []Pica_Value{input}
	return pica_inline(h, entry, args)
}
