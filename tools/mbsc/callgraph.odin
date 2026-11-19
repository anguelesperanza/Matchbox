package mbsc

import "core:fmt"
import "core:strings"

// Two checks over who calls whom:
//
//   MBS-E17  a procedure that calls itself, directly or through others. mbsc inlines every procedure, so a
//            cycle never finishes, and the targets have no call stack.
//   MBS-E26  a built-in that only exists in the fragment stage (`discard`, `ddx`, `sample_bias`, ...) reached
//            from `vertex_main`.

check_call_graph :: proc(module: ^Module) {
	check_recursion(module)
	check_vertex_stage(module)
}

// calls_from lists the calls to other procedures of the shader that a procedure makes.
@(private = "file")
calls_from :: proc(module: ^Module, caller: string) -> [dynamic]Call_Edge {
	edges := make([dynamic]Call_Edge, context.temp_allocator)
	for edge in module.edges {
		if edge.caller == caller && edge.builtin == false {
			append(&edges, edge)
		}
	}
	return edges
}

@(private = "file")
check_recursion :: proc(module: ^Module) {
	reported := make(map[string]bool, context.temp_allocator)
	for info in module.procs {
		path := make([dynamic]string, context.temp_allocator)
		taken := make([dynamic]Call_Edge, context.temp_allocator)
		finished := make(map[string]bool, context.temp_allocator)
		append(&path, info.name)
		find_cycle(module, info.name, &path, &taken, &finished, &reported)
	}
}

// find_cycle walks the calls from `name`. `path` holds the procedures on the way here, and `taken[i]` is the call
// from path[i] to path[i + 1]. A call to a procedure already on the path closes a cycle.
@(private = "file")
find_cycle :: proc(module: ^Module, name: string, path: ^[dynamic]string, taken: ^[dynamic]Call_Edge, finished: ^map[string]bool, reported: ^map[string]bool) {
	for edge in calls_from(module, name) {
		position := -1
		for on_path, index in path^ {
			if on_path == edge.callee {
				position = index
				break
			}
		}
		if position >= 0 {
			cycle := make([dynamic]Call_Edge, context.temp_allocator)
			for call in taken[position:] {
				append(&cycle, call)
			}
			append(&cycle, edge)
			report_cycle(module, cycle[:], reported)
			continue
		}
		if finished[edge.callee] {
			continue
		}
		append(path, edge.callee)
		append(taken, edge)
		find_cycle(module, edge.callee, path, taken, finished, reported)
		pop(path)
		pop(taken)
	}
	finished[name] = true
}

@(private = "file")
report_cycle :: proc(module: ^Module, cycle: []Call_Edge, reported: ^map[string]bool) {
	// The same cycle is found from each procedure in it; report it once.
	names := make([dynamic]string, context.temp_allocator)
	for edge in cycle {
		append(&names, edge.caller)
	}
	for first in 0 ..< len(names) {
		for second in first + 1 ..< len(names) {
			if names[second] < names[first] {
				names[first], names[second] = names[second], names[first]
			}
		}
	}
	key := strings.join(names[:], ",", context.temp_allocator)
	if reported[key] {
		return
	}
	reported[key] = true

	last := cycle[len(cycle) - 1]
	if len(cycle) == 1 {
		error(
			module,
			"MBS-E17",
			fmt.aprintf("`%s` calls itself", last.callee),
			last.node,
			"recursive call",
			"mbsc inlines every procedure, and the GPUs have no call stack for it to use otherwise",
			"use a `for` loop over a constant range",
		)
		return
	}

	steps := make([dynamic]string, context.temp_allocator)
	for edge in cycle {
		append(&steps, fmt.aprintf("`%s` calls `%s`", edge.caller, edge.callee))
	}
	error(
		module,
		"MBS-E17",
		fmt.aprintf("`%s` and `%s` call each other", cycle[0].caller, cycle[0].callee) if len(cycle) == 2 else fmt.aprintf("`%s` is part of a cycle of calls", last.callee),
		last.node,
		fmt.aprintf("this call closes the cycle"),
		fmt.aprintf("the calls go round in a circle: %s", strings.join(steps[:], ", then ")),
		"break the cycle, or replace the recursion with a `for` loop over a constant range",
	)
}

@(private = "file")
check_vertex_stage :: proc(module: ^Module) {
	if module.vertex_main == nil {
		return
	}
	visited := make(map[string]bool, context.temp_allocator)
	reported := make(map[rawptr]bool, context.temp_allocator)
	visit_vertex(module, module.vertex_main.name, &visited, &reported)
}

@(private = "file")
visit_vertex :: proc(module: ^Module, name: string, visited: ^map[string]bool, reported: ^map[rawptr]bool) {
	if visited[name] {
		return
	}
	visited[name] = true

	for edge in module.edges {
		if edge.caller != name {
			continue
		}
		if edge.builtin {
			builtin, found := find_builtin(edge.callee)
			if found && builtin.fragment_only && reported[edge.node] == false {
				reported[edge.node] = true
				route := "it is used in `vertex_main`" if name == module.vertex_main.name else fmt.aprintf("`%s` is called from `vertex_main`", name)
				error(
					module,
					"MBS-E26",
					fmt.aprintf("`%s` is only available in the fragment stage", edge.callee),
					edge.node,
					"not in the vertex stage",
					fmt.aprintf("%s, and the vertex stage has no pixel to %s", route, "discard" if edge.callee == "discard" else "measure or compare"),
					"do this in `fragment_main`, or pass the value through a varying",
				)
			}
		} else {
			visit_vertex(module, edge.callee, visited, reported)
		}
	}
}
