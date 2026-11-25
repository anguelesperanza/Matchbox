package mbsc

import "core:fmt"
import "core:strings"

// The instruction layer of the PICA backend: temporaries, operands, and one procedure for each shape of instruction.

PICA_LANE_LETTERS := "xyzw"

// ---- temporaries ----------------------------------------------------------------------------------------------

pica_alloc_temp :: proc(h: ^Pica) -> int {
	for index in 0 ..< PICA_TEMPORARIES {
		if h.state[index] == 0 {
			h.state[index] = 1
			append(&h.stack, Pica_Entry{index = index})
			h.highest = max(h.highest, index + 1)
			return index
		}
	}
	// out of registers: remember how many were wanted, and keep going so every problem is found in one run
	h.highest = PICA_TEMPORARIES + 1
	return PICA_TEMPORARIES - 1
}

// pica_mark is where the stack stands; pica_end_statement and pica_end_scope go back to it.
pica_mark :: proc(h: ^Pica) -> int {
	return len(h.stack)
}

// pica_end_statement lets go of what a statement used, except the variables it declared (those wait for the end of
// their block). A variable an inlined procedure declared goes with the statement that called it.
pica_end_statement :: proc(h: ^Pica, mark: int) {
	kept := mark
	for index in mark ..< len(h.stack) {
		entry := h.stack[index]
		if entry.index < 0 {
			continue
		}
		if entry.pinned && entry.depth <= h.depth && h.state[entry.index] == 2 {
			h.stack[kept] = entry
			kept += 1
		} else if h.state[entry.index] != 0 {
			h.state[entry.index] = 0
		}
	}
	resize(&h.stack, kept)
}

pica_end_scope :: proc(h: ^Pica, mark: int) {
	for index in mark ..< len(h.stack) {
		if h.stack[index].index >= 0 {
			h.state[h.stack[index].index] = 0
		}
	}
	resize(&h.stack, mark)
}

// pica_release_variable frees a variable's registers after its last use, and forgets their stack entries so a later owner of the register isn't freed by them.
pica_release_variable :: proc(h: ^Pica, var: ^IR_Var) {
	for operand in h.env[var] {
		if operand.kind != .TEMP || h.state[operand.temp] != 2 {
			continue
		}
		h.state[operand.temp] = 0
		for &entry in h.stack {
			if entry.index == operand.temp && entry.pinned {
				entry.index = -1
			}
		}
	}
}

pica_pin :: proc(h: ^Pica, index: int) {
	h.state[index] = 2
	for &entry in h.stack {
		if entry.index == index {
			entry.pinned = true
			entry.depth = h.depth
		}
	}
}

// release lets go of a temporary the expression made, once its one use has been written.
pica_release :: proc(h: ^Pica, o: Pica_Operand) {
	if o.kind == .TEMP && o.owned && h.state[o.temp] == 1 {
		h.state[o.temp] = 0
	}
}

pica_release_value :: proc(h: ^Pica, v: Pica_Value, except: Pica_Value = nil) {
	for o in v {
		keep := false
		for k in except {
			if k.kind == .TEMP && o.kind == .TEMP && k.temp == o.temp {
				keep = true
			}
		}
		if keep == false {
			pica_release(h, o)
		}
	}
}

// ---- operands -------------------------------------------------------------------------------------------------

PICA_IDENTITY :: [4]u8{0, 1, 2, 3}

pica_ident :: proc(lanes: int) -> [4]u8 {
	if lanes == 1 {
		return {0, 0, 0, 0}
	}
	return PICA_IDENTITY
}

pica_temp_operand :: proc(h: ^Pica, lanes: int) -> Pica_Operand {
	index := pica_alloc_temp(h)
	return Pica_Operand{kind = .TEMP, base = fmt.aprintf("r%d", index), swz = pica_ident(lanes), temp = index, owned = true}
}

// constant is a register holding these four numbers.
pica_constant :: proc(h: ^Pica, values: [4]f32) -> Pica_Operand {
	found := -1
	for existing, index in h.constants {
		if existing == values {
			found = index
		}
	}
	if found < 0 {
		append(&h.constants, values)
		found = len(h.constants) - 1
	}
	return Pica_Operand{kind = .CONST, base = fmt.aprintf("mbs_k%d", found), swz = PICA_IDENTITY, is_const = true, const_val = values, temp = -1}
}

pica_scalar_constant :: proc(h: ^Pica, value: f32) -> Pica_Operand {
	o := pica_constant(h, {value, value, value, value})
	o.swz = {0, 0, 0, 0}
	return o
}

// lane_value is the number a constant operand reads in a lane.
pica_lane_value :: proc(o: Pica_Operand, lane: int) -> f32 {
	value := o.const_val[o.swz[lane]]
	return -value if o.neg else value
}

pica_broadcast :: proc(o: Pica_Operand, lane: int) -> Pica_Operand {
	result := o
	component := o.swz[lane]
	result.swz = {component, component, component, component}
	return result
}

pica_negated :: proc(o: Pica_Operand) -> Pica_Operand {
	result := o
	result.neg = !o.neg
	return result
}

pica_reads_constant :: proc(o: Pica_Operand) -> bool {
	return o.kind == .CONST || o.kind == .UNIFORM
}

pica_source_text :: proc(o: Pica_Operand) -> string {
	letters: [4]u8
	for lane in 0 ..< 4 {
		letters[lane] = PICA_LANE_LETTERS[o.swz[lane]]
	}
	return fmt.aprintf("%s%s.%s", "-" if o.neg else "", o.base, string(letters[:]))
}

pica_destination_text :: proc(base: string, lanes: []int) -> string {
	letters: [4]u8
	count := 0
	for lane in 0 ..< 4 {
		for wanted in lanes {
			if wanted == lane {
				letters[count] = PICA_LANE_LETTERS[lane]
				count += 1
				break
			}
		}
	}
	return fmt.aprintf("%s.%s", base, string(letters[:count]))
}

pica_one :: proc(o: Pica_Operand) -> Pica_Value {
	result := make(Pica_Value, 1)
	result[0] = o
	return result
}

pica_first_lanes :: proc(count: int) -> []int {
	lanes := make([]int, count)
	for lane in 0 ..< count {
		lanes[lane] = lane
	}
	return lanes
}

// emit writes one instruction.
pica_emit :: proc(h: ^Pica, op: string, base: string, lanes: []int, sources: ..Pica_Operand) {
	for _ in 0 ..< h.indent {
		strings.write_byte(&h.body, '\t')
	}
	strings.write_byte(&h.body, '\t')
	strings.write_string(&h.body, op)
	strings.write_byte(&h.body, ' ')
	strings.write_string(&h.body, pica_destination_text(base, lanes))
	for source in sources {
		strings.write_string(&h.body, ", ")
		strings.write_string(&h.body, pica_source_text(source))
	}
	strings.write_byte(&h.body, '\n')
	h.count += 1
}

pica_emit_line :: proc(h: ^Pica, text: string, delta_before := 0, delta_after := 0) {
	h.indent += delta_before
	for _ in 0 ..< h.indent {
		strings.write_byte(&h.body, '\t')
	}
	strings.write_byte(&h.body, '\t')
	strings.write_string(&h.body, text)
	strings.write_byte(&h.body, '\n')
	h.indent += delta_after
}

// to_temp copies an operand into a register of its own (the `lanes` lowest components).
pica_to_temp :: proc(h: ^Pica, o: Pica_Operand, lanes: int) -> Pica_Operand {
	result := pica_temp_operand(h, lanes)
	pica_emit(h, "mov", result.base, pica_first_lanes(lanes), o)
	pica_release(h, o)
	return result
}

pica_in_register :: proc(h: ^Pica, o: Pica_Operand, lanes: int) -> Pica_Operand {
	if pica_reads_constant(o) || o.kind == .INPUT && false {
		return pica_to_temp(h, o, lanes)
	}
	return o
}

// ---- instructions ---------------------------------------------------------------------------------------------

// What an instruction does with its operands. `commutative` ones may have their sources swapped; `inverse` ones (the
// hardware's `sge`, `slt` and `dph` have an inverted form) take a constant as the second source.
pica_op_rules :: proc(op: string) -> (commutative: bool, inverse: bool) {
	switch op {
	case "add", "mul", "max", "min", "dp3", "dp4":
		return true, false
	case "sge", "slt", "dph":
		return false, true
	}
	return false, false
}

// fix_sources arranges two sources so picasso accepts them: a uniform or constant first, never negated, and not two
// different inputs together.
pica_fix_sources :: proc(h: ^Pica, op: string, a, b: Pica_Operand, lanes: int) -> (Pica_Operand, Pica_Operand) {
	a, b := a, b
	commutative, inverse := pica_op_rules(op)
	if pica_reads_constant(a) && pica_reads_constant(b) {
		b = pica_to_temp(h, b, lanes)
	}
	if pica_reads_constant(b) && inverse == false {
		if commutative && pica_reads_constant(a) == false {
			a, b = b, a
		} else {
			b = pica_to_temp(h, b, lanes)
		}
	}
	if pica_reads_constant(a) && a.neg {
		a = pica_to_temp(h, a, lanes)
	}
	if pica_reads_constant(b) && b.neg {
		b = pica_to_temp(h, b, lanes)
	}
	if a.kind == .INPUT && b.kind == .INPUT && a.base != b.base {
		b = pica_to_temp(h, b, lanes)
	}
	return a, b
}

// binary_op is `op result, a, b` into a new temporary, over the `lanes` lowest components.
pica_binary_op :: proc(h: ^Pica, op: string, a, b: Pica_Operand, lanes: int, source_lanes := 0) -> Pica_Operand {
	x, y := pica_fix_sources(h, op, a, b, source_lanes if source_lanes > 0 else lanes)
	result := pica_temp_operand(h, lanes)
	pica_emit(h, op, result.base, pica_first_lanes(lanes), x, y)
	pica_release(h, x)
	pica_release(h, y)
	return result
}

pica_unary_op :: proc(h: ^Pica, op: string, a: Pica_Operand, lanes: int) -> Pica_Operand {
	result := pica_temp_operand(h, lanes)
	pica_emit(h, op, result.base, pica_first_lanes(lanes), a)
	pica_release(h, a)
	return result
}

// scalar_op is `rcp`, `rsq`, `ex2` or `lg2`: one result from the first component, copied to every component written.
pica_scalar_op :: proc(h: ^Pica, op: string, a: Pica_Operand, lanes: int) -> Pica_Operand {
	result := pica_temp_operand(h, lanes)
	alike := true
	for lane in 1 ..< lanes {
		if a.swz[lane] != a.swz[0] {
			alike = false
		}
	}
	if alike {
		pica_emit(h, op, result.base, pica_first_lanes(lanes), a)
	} else {
		for lane in 0 ..< lanes {
			pica_emit(h, op, result.base, []int{lane}, pica_broadcast(a, lane))
		}
	}
	pica_release(h, a)
	return result
}

pica_add :: proc(h: ^Pica, a, b: Pica_Operand, lanes: int) -> Pica_Operand {
	return pica_binary_op(h, "add", a, b, lanes)
}

pica_sub :: proc(h: ^Pica, a, b: Pica_Operand, lanes: int) -> Pica_Operand {
	return pica_binary_op(h, "add", a, pica_negated(b), lanes)
}

pica_mul :: proc(h: ^Pica, a, b: Pica_Operand, lanes: int) -> Pica_Operand {
	return pica_binary_op(h, "mul", a, b, lanes)
}

// dot is the dot product of the `size` lowest components of two vectors, as a scalar.
pica_dot :: proc(h: ^Pica, a, b: Pica_Operand, size: int) -> Pica_Operand {
	result: Pica_Operand
	switch size {
	case 2:
		product := pica_mul(h, a, b, 2)
		second := pica_temp_operand(h, 1)
		first := pica_broadcast(product, 0)
		other := pica_broadcast(product, 1)
		pica_emit(h, "add", second.base, []int{0}, first, other)
		pica_release(h, product)
		return second
	case 3:
		result = pica_binary_op(h, "dp3", a, b, 1, 3)
	case:
		result = pica_binary_op(h, "dp4", a, b, 1, 4)
	}
	result.swz = {0, 0, 0, 0}
	return result
}

// ---- values -------------------------------------------------------------------------------------------------

pica_registers_of :: proc(h: ^Pica, type: ^Type) -> int {
	#partial switch type.kind {
	case .MATRIX:
		return type.rows
	case .ARRAY:
		return type.count * pica_registers_of(h, type.elem)
	case .STRUCT:
		total := 0
		for field in pica_fields_of(h, type) {
			total += pica_registers_of(h, field.type)
		}
		return total
	}
	return 1
}

pica_add_lanes :: proc(h: ^Pica, type: ^Type, lanes: ^[dynamic]int) {
	#partial switch type.kind {
	case .MATRIX:
		for _ in 0 ..< type.rows {
			append(lanes, type.cols)
		}
	case .ARRAY:
		for _ in 0 ..< type.count {
			pica_add_lanes(h, type.elem, lanes)
		}
	case .STRUCT:
		for field in pica_fields_of(h, type) {
			pica_add_lanes(h, field.type, lanes)
		}
	case:
		append(lanes, component_count(type))
	}
}

// lanes_of is how many components each register of a value of this type uses.
pica_lanes_of :: proc(h: ^Pica, type: ^Type) -> []int {
	lanes := make([dynamic]int)
	pica_add_lanes(h, type, &lanes)
	return lanes[:]
}

pica_fields_of :: proc(h: ^Pica, type: ^Type) -> []IR_Field_Info {
	if type.info.name != "" {
		return struct_fields(h.ir, type)
	}
	for uniform in h.ir.uniforms {
		if uniform.type != nil && uniform.type.info == type.info {
			return uniform.fields
		}
	}
	return nil
}

pica_zero_value :: proc(h: ^Pica, type: ^Type) -> Pica_Value {
	count := pica_registers_of(h, type)
	result := make(Pica_Value, count)
	for index in 0 ..< count {
		result[index] = pica_scalar_constant(h, 0)
	}
	return result
}

// copy_value puts a value in registers of its own, and the new variable's registers are kept until its block ends.
pica_bind_value :: proc(h: ^Pica, value: Pica_Value, type: ^Type) -> Pica_Value {
	lanes := pica_lanes_of(h, type)
	result := make(Pica_Value, len(value))
	for operand, index in value {
		if operand.kind == .TEMP && operand.owned && operand.swz == pica_ident(lanes[index]) && operand.neg == false && h.state[operand.temp] == 1 {
			pica_pin(h, operand.temp)
			result[index] = operand
			result[index].owned = false
			continue
		}
		copy := pica_temp_operand(h, lanes[index])
		pica_emit(h, "mov", copy.base, pica_first_lanes(lanes[index]), operand)
		pica_release(h, operand)
		pica_pin(h, copy.temp)
		copy.owned = false
		result[index] = copy
	}
	return result
}

// store writes `source` into registers `dest`, into the given lanes of each (all of `lanes_per_register` when `only`
// is empty). A lane of the destination takes the component of the source in the same position.
pica_store :: proc(h: ^Pica, dest: Pica_Value, lanes_per_register: []int, only: []int, source: Pica_Value) {
	for target, index in dest {
		lanes: []int
		if len(only) > 0 {
			lanes = only
		} else {
			lanes = pica_first_lanes(lanes_per_register[index])
		}
		o := source[index]
		// the source's lane j goes to destination lane lanes[j]
		swz := [4]u8{0, 1, 2, 3}
		if o.kind == .CONST || true {
			for destination_lane, j in lanes {
				swz[destination_lane] = o.swz[j]
			}
		}
		moved := o
		moved.swz = swz
		pica_emit(h, "mov", target.base, lanes, moved)
	}
}
