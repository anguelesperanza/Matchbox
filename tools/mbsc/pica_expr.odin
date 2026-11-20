package mbsc

import "core:fmt"
import "core:strings"

// Expressions of the PICA backend: uniforms, constants, arithmetic, the built-ins' instruction sequences.

// ---- uniforms ---------------------------------------------------------------------------------------------------

// Pica_Uniform_Loc says where in the declared uniforms an expression points: the name of the declaration it ends in (a
// leaf), and which of the registers of that declaration.
Pica_Uniform_Loc :: struct {
	prefix:    string, // the name so far, as the `.shbin` will have it
	type:      ^Type, // the type of the expression
	leaf_type: ^Type, // the type the declaration has, once the name is a declaration (nil while still inside a struct)
	offset:    int, // registers into the declaration
}

pica_is_leaf_type :: proc(type: ^Type) -> bool {
	current := type
	for current.kind == .ARRAY {
		current = current.elem
	}
	return current.kind != .STRUCT
}

pica_uniform_loc :: proc(h: ^Pica, e: ^IR_Expr) -> (loc: Pica_Uniform_Loc, ok: bool) {
	#partial switch node in e.variant {
	case IR_Uniform_Ref:
		loc = Pica_Uniform_Loc {
			prefix = node.name,
			type   = e.type,
		}
		if pica_is_leaf_type(e.type) {
			loc.leaf_type = e.type
		}
		return loc, true
	case IR_Field:
		base := pica_uniform_loc(h, node.base) or_return
		if base.type.kind != .STRUCT {
			return {}, false
		}
		field := pica_fields_of(h, base.type)[node.index]
		loc = Pica_Uniform_Loc {
			prefix = strings.concatenate({base.prefix, "_", field.name}),
			type   = field.type,
		}
		if pica_is_leaf_type(field.type) {
			loc.leaf_type = field.type
		}
		return loc, true
	case IR_Index:
		base := pica_uniform_loc(h, node.base) or_return
		if base.type.kind != .ARRAY {
			return {}, false
		}
		index, constant := pica_const_int(h, node.index)
		if constant == false || index < 0 || int(index) >= base.type.count {
			return {}, false
		}
		if base.leaf_type != nil {
			loc = base
			loc.type = base.type.elem
			loc.offset = base.offset + int(index) * pica_registers_of(h, base.type.elem)
			return loc, true
		}
		loc = Pica_Uniform_Loc {
			prefix = fmt.aprintf("%s_%d", base.prefix, index),
			type   = base.type.elem,
		}
		if pica_is_leaf_type(loc.type) {
			loc.leaf_type = loc.type
		}
		return loc, true
	}
	return {}, false
}

pica_declare_uniform :: proc(h: ^Pica, name: string, type: ^Type) -> string {
	safe := pica_safe_name(name)
	if h.uniform_seen[safe] == false {
		h.uniform_seen[safe] = true
		if type.kind == .I32 || type.kind == .U32 || (type.kind == .VECTOR && type.elem.kind != .F32) {
			pica_problem(h, fmt.aprintf("the uniform `%s` holds whole numbers, which the 3DS vertex unit can't take as a uniform", name))
		}
		append(&h.uniforms, Pica_Uniform{name = safe, type = type, registers = pica_registers_of(h, type), is_bool = type.kind == .BOOL})
	}
	return safe
}

// uniform_registers is the operands of the registers a uniform expression names.
pica_uniform_registers :: proc(h: ^Pica, loc: Pica_Uniform_Loc) -> Pica_Value {
	if loc.leaf_type != nil {
		name := pica_declare_uniform(h, loc.prefix, loc.leaf_type)
		count := pica_registers_of(h, loc.type)
		lanes := pica_lanes_of(h, loc.type)
		indexed := loc.leaf_type.kind == .MATRIX || loc.leaf_type.kind == .ARRAY
		result := make(Pica_Value, count)
		for index in 0 ..< count {
			base := name
			if indexed {
				base = fmt.aprintf("%s[%d]", name, loc.offset + index)
			}
			result[index] = Pica_Operand{kind = .UNIFORM, base = base, swz = pica_ident(lanes[index]), temp = -1}
		}
		return result
	}
	parts := make([dynamic]Pica_Operand)
	#partial switch loc.type.kind {
	case .STRUCT:
		for field in pica_fields_of(h, loc.type) {
			sub := Pica_Uniform_Loc {
				prefix = strings.concatenate({loc.prefix, "_", field.name}),
				type   = field.type,
			}
			if pica_is_leaf_type(field.type) {
				sub.leaf_type = field.type
			}
			append(&parts, ..pica_uniform_registers(h, sub))
		}
	case .ARRAY:
		for index in 0 ..< loc.type.count {
			sub := Pica_Uniform_Loc {
				prefix = fmt.aprintf("%s_%d", loc.prefix, index),
				type   = loc.type.elem,
			}
			if pica_is_leaf_type(sub.type) {
				sub.leaf_type = sub.type
			}
			append(&parts, ..pica_uniform_registers(h, sub))
		}
	}
	return parts[:]
}

// ---- whole numbers known when the shader is built -------------------------------------------------------------------

pica_const_int :: proc(h: ^Pica, e: ^IR_Expr) -> (value: i64, ok: bool) {
	#partial switch node in e.variant {
	case IR_Int:
		return node.value, true
	case IR_Var_Ref:
		if node.var.kind == .LOOP {
			value, ok = h.loops[node.var]
			return
		}
	case IR_Binary:
		left, left_ok := pica_const_int(h, node.left)
		right, right_ok := pica_const_int(h, node.right)
		if left_ok && right_ok {
			#partial switch node.op {
			case .ADD:
				return left + right, true
			case .SUB:
				return left - right, true
			case .MUL:
				return left * right, true
			}
		}
	}
	return 0, false
}

pica_const_bool :: proc(h: ^Pica, e: ^IR_Expr) -> (value: bool, ok: bool) {
	#partial switch node in e.variant {
	case IR_Bool:
		return node.value, true
	case IR_Unary:
		if node.op == .NOT {
			inner := pica_const_bool(h, node.operand) or_return
			return !inner, true
		}
	case IR_Binary:
		#partial switch node.op {
		case .AND, .OR:
			left := pica_const_bool(h, node.left) or_return
			right := pica_const_bool(h, node.right) or_return
			return (left && right) if node.op == .AND else (left || right), true
		case .LESS, .GREATER, .LESS_EQUAL, .GREATER_EQUAL, .EQUAL, .NOT_EQUAL:
			left := pica_const_int(h, node.left) or_return
			right := pica_const_int(h, node.right) or_return
			#partial switch node.op {
			case .LESS:
				return left < right, true
			case .GREATER:
				return left > right, true
			case .LESS_EQUAL:
				return left <= right, true
			case .GREATER_EQUAL:
				return left >= right, true
			case .EQUAL:
				return left == right, true
			case .NOT_EQUAL:
				return left != right, true
			}
		}
	}
	return false, false
}

// ---- expressions ------------------------------------------------------------------------------------------------

pica_fail :: proc(h: ^Pica, e: ^IR_Expr, text: string) -> Pica_Value {
	pica_problem(h, text)
	return pica_zero_value(h, e.type)
}

// pica_eval writes the instructions for an expression and returns where its value is.
pica_eval :: proc(h: ^Pica, e: ^IR_Expr) -> Pica_Value {
	if loc, is_uniform := pica_uniform_loc(h, e); is_uniform {
		if loc.type.kind == .BOOL {
			return pica_fail(h, e, "a boolean uniform can only be used as the condition of an `if`")
		}
		return pica_uniform_registers(h, loc)
	}

	switch node in e.variant {
	case IR_Float:
		return pica_one(pica_scalar_constant(h, node.value))
	case IR_Int:
		return pica_one(pica_scalar_constant(h, f32(node.value)))
	case IR_Bool:
		return pica_fail(h, e, "a boolean value can only be used as a condition on the 3DS")
	case IR_Zero:
		return pica_zero_value(h, e.type)
	case IR_Var_Ref:
		if node.var.kind == .LOOP {
			value, known := h.loops[node.var]
			if known {
				return pica_one(pica_scalar_constant(h, f32(value)))
			}
		}
		if value, found := h.env[node.var]; found {
			return value
		}
		return pica_fail(h, e, fmt.aprintf("`%s` is used before it is set", node.var.name))
	case IR_Uniform_Ref:
		return pica_fail(h, e, "a uniform struct is read one field at a time")
	case IR_Texture_Ref:
		return pica_fail(h, e, "a texture can't be read in the 3DS vertex stage")
	case IR_Unary:
		if node.op == .NOT {
			return pica_fail(h, e, "`!` on the 3DS works on a condition, not on a value")
		}
		value := pica_eval(h, node.operand)
		result := make(Pica_Value, len(value))
		for operand, index in value {
			result[index] = operand
			if operand.is_const && operand.kind == .CONST {
				flipped := operand.const_val
				for lane in 0 ..< 4 {
					flipped[lane] = -flipped[lane]
				}
				result[index] = pica_constant(h, flipped)
				result[index].swz = operand.swz
			} else {
				result[index] = pica_negated(operand)
			}
		}
		return result
	case IR_Binary:
		return pica_arithmetic(h, e, node)
	case IR_Swizzle:
		value := pica_eval(h, node.base)
		o := value[0]
		result := o
		for lane in 0 ..< 4 {
			picked := min(lane, node.count - 1)
			result.swz[lane] = o.swz[node.indices[picked]]
		}
		return pica_one(result)
	case IR_Field:
		base := pica_eval(h, node.base)
		offset := 0
		fields := pica_fields_of(h, node.base.type)
		for index in 0 ..< node.index {
			offset += pica_registers_of(h, fields[index].type)
		}
		return base[offset:offset + pica_registers_of(h, e.type)]
	case IR_Index:
		base := pica_eval(h, node.base)
		index, known := pica_const_int(h, node.index)
		if known == false {
			return pica_fail(h, e, "an index the shader computes can't be written on the 3DS; use a constant or a `for` counter")
		}
		#partial switch node.base.type.kind {
		case .ARRAY:
			size := pica_registers_of(h, node.base.type.elem)
			return base[int(index) * size:int(index + 1) * size]
		case .VECTOR:
			return pica_one(pica_broadcast(base[0], int(index)))
		}
		return pica_fail(h, e, "indexing a matrix isn't written for the 3DS yet; multiply it by a vector")
	case IR_Convert:
		if value, known := pica_const_int(h, node.operand); known {
			return pica_one(pica_scalar_constant(h, f32(value)))
		}
		return pica_fail(h, e, "a conversion between numbers isn't written for the 3DS vertex stage")
	case IR_Construct:
		return pica_construct(h, e, node)
	case IR_Builtin_Call:
		return pica_builtin(h, e, node)
	case IR_Proc_Call:
		args := make([]Pica_Value, len(node.args))
		for arg, index in node.args {
			args[index] = pica_eval(h, arg)
		}
		return pica_inline(h, node.callee, args)
	}
	return pica_fail(h, e, "an expression the 3DS backend doesn't know")
}

pica_arithmetic :: proc(h: ^Pica, e: ^IR_Expr, node: IR_Binary) -> Pica_Value {
	#partial switch node.op {
	case .ADD, .SUB, .MUL, .DIV:
	case:
		return pica_fail(h, e, "a comparison or a boolean can only be used as a condition on the 3DS")
	}
	left_type, right_type := node.left.type, node.right.type

	if left_type.kind == .MATRIX || right_type.kind == .MATRIX {
		if node.op != .MUL {
			return pica_fail(h, e, "only `matrix * vector` and `vector * matrix` are written for the 3DS")
		}
		if left_type.kind == .MATRIX && is_float_vector(right_type) && left_type.cols == right_type.count {
			rows := pica_eval(h, node.left)
			vector := pica_eval(h, node.right)[0]
			return pica_one(pica_matrix_times_vector(h, rows, vector, left_type.rows, left_type.cols))
		}
		if right_type.kind == .MATRIX && is_float_vector(left_type) && left_type.count == right_type.rows {
			vector := pica_eval(h, node.left)[0]
			rows := pica_eval(h, node.right)
			return pica_one(pica_vector_times_matrix(h, vector, rows, right_type.rows, right_type.cols))
		}
		return pica_fail(h, e, "this matrix product isn't written for the 3DS")
	}
	if is_float_gen(e.type) == false {
		return pica_fail(h, e, "whole-number arithmetic isn't available on the 3DS")
	}

	lanes := component_count(e.type)
	a := pica_eval(h, node.left)[0]

	if node.op == .DIV {
		if literal, is_literal := node.right.variant.(IR_Float); is_literal && literal.value != 0 {
			return pica_one(pica_mul(h, a, pica_scalar_constant(h, 1.0 / literal.value), lanes))
		}
		b := pica_eval(h, node.right)[0]
		reciprocal := pica_scalar_op(h, "rcp", b, component_count(node.right.type))
		return pica_one(pica_mul(h, a, reciprocal, lanes))
	}
	b := pica_eval(h, node.right)[0]
	#partial switch node.op {
	case .ADD:
		return pica_one(pica_add(h, a, b, lanes))
	case .SUB:
		return pica_one(pica_sub(h, a, b, lanes))
	}
	return pica_one(pica_mul(h, a, b, lanes))
}

// matrix_times_vector is one dot product per row, each into its own component of the result.
pica_matrix_times_vector :: proc(h: ^Pica, rows: Pica_Value, vector: Pica_Operand, row_count, size: int) -> Pica_Operand {
	result := pica_temp_operand(h, row_count)
	for row, index in rows {
		if size == 2 {
			product := pica_dot(h, row, vector, 2)
			pica_emit(h, "mov", result.base, []int{index}, product)
			pica_release(h, product)
			continue
		}
		op := "dp3" if size == 3 else "dp4"
		x, y := pica_fix_sources(h, op, row, vector, size)
		pica_emit(h, op, result.base, []int{index}, x, y)
		if x.owned && x.base != vector.base {
			pica_release(h, x)
		}
		if y.owned && y.base != vector.base {
			pica_release(h, y)
		}
	}
	pica_release(h, vector)
	return result
}

// vector_times_matrix adds up the rows, each scaled by one component of the vector.
pica_vector_times_matrix :: proc(h: ^Pica, vector: Pica_Operand, rows: Pica_Value, row_count, size: int) -> Pica_Operand {
	kept := vector
	kept.owned = false
	total := pica_mul(h, rows[0], pica_broadcast(kept, 0), size)
	for index in 1 ..< row_count {
		term := pica_mul(h, rows[index], pica_broadcast(kept, index), size)
		total = pica_add(h, total, term, size)
	}
	pica_release(h, vector)
	return total
}

// construct builds a vector, array, struct or matrix.
pica_construct :: proc(h: ^Pica, e: ^IR_Expr, node: IR_Construct) -> Pica_Value {
	#partial switch e.type.kind {
	case .ARRAY, .STRUCT:
		parts := make([dynamic]Pica_Operand)
		for arg in node.args {
			append(&parts, ..pica_eval(h, arg))
		}
		return parts[:]
	case .VECTOR:
		components := make([dynamic]Pica_Operand)
		for arg in node.args {
			value := pica_eval(h, arg)
			for lane in 0 ..< component_count(arg.type) {
				append(&components, pica_broadcast(value[0], lane))
			}
		}
		return pica_one(pica_gather(h, components[:], e.type.count))
	case .MATRIX:
		if len(node.args) != e.type.rows * e.type.cols {
			return pica_fail(h, e, "a matrix written from vectors isn't written for the 3DS yet; write all its numbers")
		}
		rows := make(Pica_Value, e.type.rows)
		for row in 0 ..< e.type.rows {
			components := make([dynamic]Pica_Operand)
			for column in 0 ..< e.type.cols {
				append(&components, pica_eval(h, node.args[row * e.type.cols + column])[0])
			}
			rows[row] = pica_gather(h, components[:], e.type.cols)
		}
		return rows
	}
	return pica_fail(h, e, "this value can't be built on the 3DS")
}

// gather puts the components (each a scalar operand) in the lowest lanes of one register.
pica_gather :: proc(h: ^Pica, components: []Pica_Operand, lanes: int) -> Pica_Operand {
	if len(components) == 1 {
		return components[0]
	}
	all_constant := true
	for component in components {
		if component.is_const == false || component.kind != .CONST {
			all_constant = false
		}
	}
	if all_constant {
		values: [4]f32
		for component, lane in components {
			values[lane] = pica_lane_value(component, 0)
		}
		return pica_constant(h, values)
	}

	result := pica_temp_operand(h, lanes)
	done := make([]bool, len(components))
	for index in 0 ..< len(components) {
		if done[index] {
			continue
		}
		group := make([dynamic]int)
		swz := [4]u8{0, 1, 2, 3}
		for other in index ..< len(components) {
			if done[other] == false && components[other].base == components[index].base && components[other].neg == components[index].neg {
				done[other] = true
				append(&group, other)
				swz[other] = components[other].swz[0]
			}
		}
		source := components[index]
		source.swz = swz
		pica_emit(h, "mov", result.base, group[:], source)
	}
	for component in components {
		pica_release(h, component)
	}
	return result
}

// ---- built-ins ------------------------------------------------------------------------------------------------------

pica_keep :: proc(o: Pica_Operand) -> Pica_Operand {
	result := o
	result.owned = false
	return result
}

pica_permuted :: proc(o: Pica_Operand, first, second, third: u8) -> Pica_Operand {
	result := o
	result.swz = {o.swz[first], o.swz[second], o.swz[third], o.swz[third]}
	return result
}

pica_trunc_op :: proc(h: ^Pica, a: Pica_Operand, lanes: int) -> Pica_Operand {
	zero := pica_scalar_constant(h, 0)
	ak := pica_keep(pica_in_register(h, a, lanes))
	positive := pica_binary_op(h, "sge", ak, zero, lanes)
	negative := pica_binary_op(h, "slt", ak, zero, lanes)
	sign := pica_sub(h, positive, negative, lanes)
	magnitude := pica_binary_op(h, "max", ak, pica_negated(ak), lanes)
	whole := pica_unary_op(h, "flr", magnitude, lanes)
	pica_release(h, ak)
	return pica_mul(h, whole, sign, lanes)
}

pica_reciprocal_of :: proc(h: ^Pica, b: Pica_Operand, lanes: int) -> Pica_Operand {
	return pica_scalar_op(h, "rcp", b, lanes)
}

// pica_builtin writes the instruction sequence of a built-in. The sequences are the ones of tools/mbsc_probe.odin,
// which picasso accepts; the tests check the numbers they give.
pica_builtin :: proc(h: ^Pica, e: ^IR_Expr, node: IR_Builtin_Call) -> Pica_Value {
	args := make([]Pica_Operand, len(node.args))
	for arg, index in node.args {
		if arg.type.kind == .TEXTURE2D {
			continue
		}
		value := pica_eval(h, arg)
		args[index] = value[0]
	}
	lanes := component_count(e.type)
	zero, one, half := pica_scalar_constant(h, 0), pica_scalar_constant(h, 1), pica_scalar_constant(h, 0.5)
	result: Pica_Operand

	switch node.name {
	case "abs":
		a := pica_in_register(h, args[0], lanes)
		ak := pica_keep(a)
		result = pica_binary_op(h, "max", ak, pica_negated(ak), lanes)
		pica_release(h, a)
	case "sign":
		a := pica_keep(pica_in_register(h, args[0], lanes))
		positive := pica_binary_op(h, "slt", zero, a, lanes)
		negative := pica_binary_op(h, "slt", a, zero, lanes)
		result = pica_sub(h, positive, negative, lanes)
		pica_release(h, args[0])
	case "floor":
		result = pica_unary_op(h, "flr", args[0], lanes)
	case "ceil":
		flipped := pica_unary_op(h, "flr", pica_negated(args[0]), lanes)
		result = pica_unary_op(h, "mov", pica_negated(flipped), lanes)
	case "trunc":
		result = pica_trunc_op(h, args[0], lanes)
	case "round":
		x := pica_keep(pica_in_register(h, args[0], lanes))
		shifted := pica_add(h, x, half, lanes)
		r := pica_keep(pica_unary_op(h, "flr", shifted, lanes))
		gap := pica_sub(h, r, x, lanes)
		tie := pica_binary_op(h, "sge", gap, half, lanes)
		halved := pica_mul(h, r, half, lanes)
		fl := pica_unary_op(h, "flr", halved, lanes)
		twice := pica_mul(h, fl, pica_scalar_constant(h, 2), lanes)
		odd := pica_sub(h, r, twice, lanes)
		correction := pica_mul(h, tie, odd, lanes)
		result = pica_sub(h, r, correction, lanes)
		pica_release(h, r)
		pica_release(h, args[0])
	case "fract":
		a := pica_keep(pica_in_register(h, args[0], lanes))
		whole := pica_unary_op(h, "flr", a, lanes)
		result = pica_sub(h, a, whole, lanes)
		pica_release(h, args[0])
	case "saturate":
		floor_applied := pica_binary_op(h, "max", args[0], zero, lanes)
		result = pica_binary_op(h, "min", floor_applied, one, lanes)
	case "min", "max":
		result = pica_binary_op(h, node.name, args[0], args[1], lanes)
	case "clamp":
		low := pica_binary_op(h, "max", args[0], args[1], lanes)
		result = pica_binary_op(h, "min", low, args[2], lanes)
	case "fmod", "mod":
		a := pica_keep(pica_in_register(h, args[0], lanes))
		b := pica_keep(pica_in_register(h, args[1], lanes))
		reciprocal := pica_reciprocal_of(h, b, component_count(node.args[1].type))
		quotient := pica_mul(h, a, reciprocal, lanes)
		whole: Pica_Operand
		if node.name == "fmod" {
			whole = pica_trunc_op(h, quotient, lanes)
		} else {
			whole = pica_unary_op(h, "flr", quotient, lanes)
		}
		scaled := pica_mul(h, b, whole, lanes)
		result = pica_sub(h, a, scaled, lanes)
		pica_release(h, a)
		pica_release(h, b)
	case "step":
		result = pica_binary_op(h, "sge", args[1], args[0], lanes)
	case "lerp":
		a := pica_keep(args[0])
		difference := pica_sub(h, args[1], a, lanes)
		scaled := pica_mul(h, difference, args[2], lanes)
		result = pica_add(h, a, scaled, lanes)
		pica_release(h, args[0])
	case "smoothstep":
		low := pica_keep(args[0])
		numerator := pica_sub(h, args[2], low, lanes)
		denominator := pica_sub(h, args[1], low, lanes)
		reciprocal := pica_scalar_op(h, "rcp", denominator, lanes)
		t := pica_mul(h, numerator, reciprocal, lanes)
		t = pica_binary_op(h, "max", t, zero, lanes)
		t = pica_keep(pica_binary_op(h, "min", t, one, lanes))
		square := pica_mul(h, t, t, lanes)
		doubled := pica_mul(h, t, pica_scalar_constant(h, 2), lanes)
		shaped := pica_sub(h, pica_scalar_constant(h, 3), doubled, lanes)
		result = pica_mul(h, square, shaped, lanes)
		pica_release(h, t)
		pica_release(h, args[0])
	case "sqrt":
		root := pica_scalar_op(h, "rsq", args[0], lanes)
		result = pica_scalar_op(h, "rcp", root, lanes)
	case "inverse_sqrt":
		result = pica_scalar_op(h, "rsq", args[0], lanes)
	case "exp2":
		result = pica_scalar_op(h, "ex2", args[0], lanes)
	case "log2":
		result = pica_scalar_op(h, "lg2", args[0], lanes)
	case "exp":
		scaled := pica_mul(h, args[0], pica_scalar_constant(h, 1.4426950408889634), lanes)
		result = pica_scalar_op(h, "ex2", scaled, lanes)
	case "ln":
		logarithm := pica_scalar_op(h, "lg2", args[0], lanes)
		result = pica_mul(h, logarithm, pica_scalar_constant(h, 0.6931471805599453), lanes)
	case "log10":
		logarithm := pica_scalar_op(h, "lg2", args[0], lanes)
		result = pica_mul(h, logarithm, pica_scalar_constant(h, 0.30102999566398120), lanes)
	case "pow":
		logarithm := pica_scalar_op(h, "lg2", args[0], lanes)
		scaled := pica_mul(h, args[1], logarithm, lanes)
		result = pica_scalar_op(h, "ex2", scaled, lanes)
	case "to_radians":
		result = pica_mul(h, args[0], pica_scalar_constant(h, 0.017453292519943295), lanes)
	case "to_degrees":
		result = pica_mul(h, args[0], pica_scalar_constant(h, 57.29577951308232), lanes)
	case "sin_approx", "cos_approx":
		result = pica_polynomial(h, args[0], lanes, node.name == "sin_approx")
	case "dot":
		a, b := pica_keep(args[0]), pica_keep(args[1])
		result = pica_dot(h, a, b, component_count(node.args[0].type))
		pica_release(h, args[0])
		pica_release(h, args[1])
	case "length":
		size := component_count(node.args[0].type)
		a := pica_keep(args[0])
		squared := pica_dot(h, a, a, size)
		pica_release(h, args[0])
		inverse := pica_scalar_op(h, "rsq", squared, 1)
		result = pica_scalar_op(h, "rcp", inverse, 1)
	case "distance":
		size := component_count(node.args[0].type)
		difference := pica_keep(pica_sub(h, args[0], args[1], size))
		squared := pica_dot(h, difference, difference, size)
		pica_release(h, difference)
		inverse := pica_scalar_op(h, "rsq", squared, 1)
		result = pica_scalar_op(h, "rcp", inverse, 1)
	case "normalize":
		size := component_count(node.args[0].type)
		a := pica_keep(args[0])
		squared := pica_dot(h, a, a, size)
		inverse := pica_scalar_op(h, "rsq", squared, 1)
		result = pica_mul(h, a, inverse, size)
		pica_release(h, args[0])
	case "cross":
		a, b := pica_keep(args[0]), pica_keep(args[1])
		first := pica_mul(h, pica_permuted(a, 2, 0, 1), pica_permuted(b, 1, 2, 0), 3)
		second := pica_mul(h, pica_permuted(a, 1, 2, 0), pica_permuted(b, 2, 0, 1), 3)
		result = pica_sub(h, second, first, 3)
		pica_release(h, args[0])
		pica_release(h, args[1])
	case "reflect":
		size := component_count(node.args[0].type)
		i, n := pica_keep(args[0]), pica_keep(args[1])
		projection := pica_dot(h, n, i, size)
		doubled := pica_add(h, projection, pica_keep(projection), 1)
		scaled := pica_mul(h, n, doubled, size)
		result = pica_sub(h, i, scaled, size)
		pica_release(h, args[0])
		pica_release(h, args[1])
	case "refract":
		i, n, eta := pica_keep(args[0]), pica_keep(args[1]), pica_keep(args[2])
		projection := pica_keep(pica_dot(h, n, i, 3))
		projection_squared := pica_mul(h, projection, projection, 1)
		remaining := pica_sub(h, one, projection_squared, 1)
		eta_squared := pica_mul(h, eta, eta, 1)
		scaled := pica_mul(h, eta_squared, remaining, 1)
		k := pica_keep(pica_sub(h, one, scaled, 1))
		inside := pica_binary_op(h, "sge", k, zero, 1)
		clamped := pica_binary_op(h, "max", zero, k, 1)
		inverse := pica_scalar_op(h, "rsq", clamped, 1)
		root := pica_scalar_op(h, "rcp", inverse, 1)
		eta_projection := pica_mul(h, eta, projection, 1)
		weight := pica_add(h, eta_projection, root, 1)
		normal_part := pica_mul(h, n, weight, 3)
		incident_part := pica_mul(h, eta, i, 3)
		bent := pica_sub(h, incident_part, normal_part, 3)
		result = pica_mul(h, bent, inside, 3)
		pica_release(h, args[0])
		pica_release(h, args[1])
		pica_release(h, args[2])
		pica_release(h, projection)
		pica_release(h, k)
	case:
		pica_problem(h, fmt.aprintf("`%s` isn't written for the 3DS vertex stage", node.name))
		return pica_zero_value(h, e.type)
	}
	return pica_one(result)
}

// polynomial is `sin_approx` or `cos_approx`: the argument reduction and the Horner evaluation of section 15 of the
// language reference.
pica_polynomial :: proc(h: ^Pica, argument: Pica_Operand, lanes: int, sine: bool) -> Pica_Operand {
	a := pica_keep(pica_in_register(h, argument, lanes))
	scaled := pica_mul(h, a, pica_scalar_constant(h, 0.15915494309189535), lanes)
	shifted := pica_add(h, scaled, pica_scalar_constant(h, 0.5), lanes)
	k := pica_unary_op(h, "flr", shifted, lanes)
	turns := pica_mul(h, k, pica_scalar_constant(h, -6.283185307179586), lanes)
	r := pica_keep(pica_add(h, a, turns, lanes))
	t := pica_keep(pica_mul(h, r, r, lanes))

	coefficients: []f32
	if sine {
		coefficients = {2.1478728533851322e-06, -0.0001926499619928568, 0.008308984952537351, -0.16662438501484986, 0.9999793879828708}
	} else {
		coefficients = {-2.1978878103077777e-07, 2.4204400324072683e-05, -0.001385891587244809, 0.041659822182074986, -0.4999942680922626, 0.9999992215743202}
	}
	p := pica_unary_op(h, "mov", pica_scalar_constant(h, coefficients[0]), lanes)
	for coefficient in coefficients[1:] {
		p = pica_mul(h, p, t, lanes)
		p = pica_add(h, pica_scalar_constant(h, coefficient), p, lanes)
	}
	pica_release(h, t)
	pica_release(h, a)
	if sine {
		result := pica_mul(h, r, p, lanes)
		pica_release(h, r)
		return result
	}
	pica_release(h, r)
	return p
}
