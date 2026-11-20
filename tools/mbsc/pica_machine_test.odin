package mbsc

import "core:math"
import "core:strconv"
import "core:strings"

// A small PICA200 vertex unit, enough to run what generate_pica writes: it reads the text of a `.v.pica` file and
// runs `main`. The tests compare its results with a plain evaluation of the intermediate form (ir_eval_test.odin), so
// the instruction sequences are checked for the numbers they give, not only for being accepted by picasso.
//
// The rules it follows are the hardware's: a source operand's swizzle is applied first, the result of an instruction
// is written to the lanes of the destination mask, lane `i` of the destination taking lane `i` of the result, and
// `rcp`, `rsq`, `ex2` and `lg2` read the first component of their source and write that one result to every lane.

Machine :: struct {
	temps:    [16][4]f32,
	inputs:   [16][4]f32,
	floats:   map[string][][4]f32, // uniforms and constants by name; an array has one entry per register
	bools:    map[string]bool,
	outputs:  map[string][4]f32,
	cmp:      [2]bool,
	executed: int,
}

@(private = "file")
Source :: struct {
	name:  string,
	index: int,
	swz:   [4]int,
	neg:   bool,
}

@(private = "file")
lane_index :: proc(letter: u8) -> int {
	switch letter {
	case 'x', 'r':
		return 0
	case 'y', 'g':
		return 1
	case 'z', 'b':
		return 2
	}
	return 3
}

// split_operand takes `-name[2].xyzw` apart.
@(private = "file")
split_operand :: proc(text: string) -> (source: Source) {
	rest := strings.trim_space(text)
	if strings.has_prefix(rest, "-") {
		source.neg = true
		rest = rest[1:]
	}
	suffix := ""
	if dot := strings.last_index_byte(rest, '.'); dot >= 0 {
		suffix = rest[dot + 1:]
		rest = rest[:dot]
	}
	source.swz = {0, 1, 2, 3}
	if len(suffix) > 0 {
		for lane in 0 ..< 4 {
			source.swz[lane] = lane_index(suffix[min(lane, len(suffix) - 1)])
		}
	}
	if open := strings.index_byte(rest, '['); open >= 0 {
		close := strings.index_byte(rest, ']')
		index, _ := strconv.parse_int(rest[open + 1:close])
		source.index = index
		rest = rest[:open]
	}
	source.name = rest
	return
}

@(private = "file")
read_register :: proc(m: ^Machine, source: Source) -> [4]f32 {
	value: [4]f32
	switch {
	case strings.has_prefix(source.name, "r") && len(source.name) <= 3 && source.name[1] >= '0' && source.name[1] <= '9':
		index, _ := strconv.parse_int(source.name[1:])
		value = m.temps[index]
	case strings.has_prefix(source.name, "v") && len(source.name) <= 3 && source.name[1] >= '0' && source.name[1] <= '9':
		index, _ := strconv.parse_int(source.name[1:])
		value = m.inputs[index]
	case:
		registers, found := m.floats[source.name]
		if found && source.index < len(registers) {
			value = registers[source.index]
		}
	}
	result: [4]f32
	for lane in 0 ..< 4 {
		result[lane] = value[source.swz[lane]]
		if source.neg {
			result[lane] = -result[lane]
		}
	}
	return result
}

@(private = "file")
write_register :: proc(m: ^Machine, text: string, value: [4]f32) {
	rest := strings.trim_space(text)
	mask := "xyzw"
	if dot := strings.index_byte(rest, '.'); dot >= 0 {
		mask = rest[dot + 1:]
		rest = rest[:dot]
	}
	target: ^[4]f32
	if strings.has_prefix(rest, "r") && len(rest) <= 3 && rest[1] >= '0' && rest[1] <= '9' {
		index, _ := strconv.parse_int(rest[1:])
		target = &m.temps[index]
	} else {
		current := m.outputs[rest]
		for lane in 0 ..< len(mask) {
			index := lane_index(mask[lane])
			current[index] = value[index]
		}
		m.outputs[rest] = current
		return
	}
	for lane in 0 ..< len(mask) {
		index := lane_index(mask[lane])
		target[index] = value[index]
	}
}

// machine_load reads the `.fvec`, `.constf` and `.bool` lines; the caller then fills in the uniforms.
machine_load :: proc(m: ^Machine, text: string) -> (lines: []string) {
	context.allocator = context.temp_allocator
	body := make([dynamic]string)
	in_proc := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == ';' {
			continue
		}
		switch {
		case strings.has_prefix(trimmed, ".fvec "):
			declaration := strings.trim_space(trimmed[len(".fvec "):])
			count := 1
			if open := strings.index_byte(declaration, '['); open >= 0 {
				count, _ = strconv.parse_int(declaration[open + 1:strings.index_byte(declaration, ']')])
				declaration = declaration[:open]
			}
			m.floats[declaration] = make([][4]f32, count)
		case strings.has_prefix(trimmed, ".constf "):
			declaration := trimmed[len(".constf "):]
			open := strings.index_byte(declaration, '(')
			numbers := strings.split(declaration[open + 1:strings.index_byte(declaration, ')')], ",")
			value: [4]f32
			for number, lane in numbers {
				parsed, _ := strconv.parse_f32(strings.trim_space(number))
				value[lane] = parsed
			}
			registers := make([][4]f32, 1)
			registers[0] = value
			m.floats[strings.trim_space(declaration[:open])] = registers
		case strings.has_prefix(trimmed, ".bool "):
			m.bools[strings.trim_space(trimmed[len(".bool "):])] = false
		case strings.has_prefix(trimmed, ".out "):
		case trimmed == ".proc main":
			in_proc = true
		case in_proc:
			append(&body, trimmed)
		}
	}
	return body[:]
}

@(private = "file")
split_arguments :: proc(text: string) -> []string {
	context.allocator = context.temp_allocator
	parts := strings.split(text, ", ")
	for &part in parts {
		part = strings.trim_space(part)
	}
	return parts
}

@(private = "file")
skip_to :: proc(lines: []string, from: int, stop_at_else: bool) -> int {
	depth := 0
	for index := from; index < len(lines); index += 1 {
		line := lines[index]
		if strings.has_prefix(line, "ifc ") || strings.has_prefix(line, "ifu ") {
			depth += 1
		} else if line == ".end" {
			if depth == 0 {
				return index
			}
			depth -= 1
		} else if line == ".else" && depth == 0 && stop_at_else {
			return index
		}
	}
	return len(lines)
}

// machine_run runs the lines `machine_load` returned.
machine_run :: proc(m: ^Machine, lines: []string) {
	index := 0
	for index < len(lines) {
		line := lines[index]
		index += 1
		m.executed += 1
		if line == "end" {
			return
		}
		if line == ".else" {
			index = skip_to(lines, index, false) + 1
			continue
		}
		if line == ".end" {
			continue
		}
		if strings.has_prefix(line, "ifu ") {
			if m.bools[strings.trim_space(line[4:])] == false {
				stop := skip_to(lines, index, true)
				index = stop + 1
			}
			continue
		}
		if strings.has_prefix(line, "ifc ") {
			condition := strings.trim_space(line[4:])
			truth: bool
			switch {
			case strings.contains(condition, "&&"):
				truth = m.cmp[0] && m.cmp[1]
			case strings.contains(condition, "||"):
				truth = m.cmp[0] || m.cmp[1]
			case:
				truth = m.cmp[0]
			}
			if truth == false {
				stop := skip_to(lines, index, true)
				index = stop + 1
			}
			continue
		}
		if strings.has_prefix(line, "cmp ") {
			arguments := split_arguments(line[4:])
			a := read_register(m, split_operand(arguments[0]))
			b := read_register(m, split_operand(arguments[3]))
			for lane in 0 ..< 2 {
				op := arguments[1 + lane]
				m.cmp[lane] = compare(op, a[lane], b[lane])
			}
			continue
		}

		space := strings.index_byte(line, ' ')
		op := line[:space]
		arguments := split_arguments(line[space + 1:])
		sources := make([dynamic][4]f32, context.temp_allocator)
		for argument in arguments[1:] {
			append(&sources, read_register(m, split_operand(argument)))
		}
		a: [4]f32
		b: [4]f32
		if len(sources) > 0 {
			a = sources[0]
		}
		if len(sources) > 1 {
			b = sources[1]
		}
		result: [4]f32
		switch op {
		case "mov":
			result = a
		case "add":
			for lane in 0 ..< 4 {
				result[lane] = a[lane] + b[lane]
			}
		case "mul":
			for lane in 0 ..< 4 {
				result[lane] = a[lane] * b[lane]
			}
		case "max":
			for lane in 0 ..< 4 {
				result[lane] = max(a[lane], b[lane])
			}
		case "min":
			for lane in 0 ..< 4 {
				result[lane] = min(a[lane], b[lane])
			}
		case "slt":
			for lane in 0 ..< 4 {
				result[lane] = 1 if a[lane] < b[lane] else 0
			}
		case "sge":
			for lane in 0 ..< 4 {
				result[lane] = 1 if a[lane] >= b[lane] else 0
			}
		case "flr":
			for lane in 0 ..< 4 {
				result[lane] = math.floor(a[lane])
			}
		case "dp3":
			value := a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
			result = {value, value, value, value}
		case "dp4":
			value := a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
			result = {value, value, value, value}
		case "dph":
			value := a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + b[3]
			result = {value, value, value, value}
		case "rcp":
			value := 1.0 / a[0]
			result = {value, value, value, value}
		case "rsq":
			value := 1.0 / math.sqrt(a[0])
			result = {value, value, value, value}
		case "ex2":
			value := math.pow(f32(2), a[0])
			result = {value, value, value, value}
		case "lg2":
			value := math.log2(a[0])
			result = {value, value, value, value}
		case:
			panic(strings.concatenate({"the machine doesn't know the instruction `", op, "`"}, context.temp_allocator))
		}
		write_register(m, arguments[0], result)
	}
}

@(private = "file")
compare :: proc(op: string, a, b: f32) -> bool {
	switch op {
	case "lt":
		return a < b
	case "gt":
		return a > b
	case "le":
		return a <= b
	case "ge":
		return a >= b
	case "eq":
		return a == b
	}
	return a != b
}
