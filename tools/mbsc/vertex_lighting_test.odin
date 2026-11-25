package mbsc

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

/*
	mesh_vertex_lit.mbs (G2 L5-1) against the lighting model worked out here in f64, on scenes made from random
	numbers: a model turned, scaled and moved, a camera looking at it, 1 to 8 lights, suns, point lights and spots (the slots after
	them empty, as the engine leaves them), and random colours and materials. Two runs of the vertex stage are
	checked:
	- the IR interpreter, which is what the shader means on every target;
	- the 3DS's program, run on the PICA machine model, whose `rsq`, `lg2` and `ex2` are exact, so it agrees closely
	  with the interpreter. The real unit's are not exact: that is for the hardware pass.
	The reference is written from the description in the shader's comment and lighting.odin, not from the shader, so
	it checks the shader rather than repeating it.
*/

@(private = "file")
Random :: struct {
	state: u32,
}

@(private = "file")
next_random :: proc(r: ^Random, low, high: f64) -> f64 {
	r.state = r.state * 1664525 + 1013904223
	return low + (high - low) * f64(r.state >> 8) / f64(1 << 24)
}

@(private = "file")
Vector3 :: [3]f64

@(private = "file")
Matrix4 :: [4][4]f64 // rows, as the shader's literal and the interpreter's flat lists have them

@(private = "file")
multiply :: proc(m: Matrix4, v: [4]f64) -> (result: [4]f64) {
	for row in 0 ..< 4 {
		for column in 0 ..< 4 do result[row] += m[row][column] * v[column]
	}
	return
}

@(private = "file")
multiply_matrices :: proc(a, b: Matrix4) -> (result: Matrix4) {
	for row in 0 ..< 4 {
		for column in 0 ..< 4 {
			for k in 0 ..< 4 do result[row][column] += a[row][k] * b[k][column]
		}
	}
	return
}

@(private = "file")
dot3 :: proc(a, b: Vector3) -> f64 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

@(private = "file")
unit :: proc(v: Vector3) -> Vector3 {
	return v / math.sqrt(dot3(v, v))
}

@(private = "file")
cross3 :: proc(a, b: Vector3) -> Vector3 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

@(private = "file")
random_unit :: proc(r: ^Random) -> Vector3 {
	for {
		v := Vector3{next_random(r, -1, 1), next_random(r, -1, 1), next_random(r, -1, 1)}
		length := math.sqrt(dot3(v, v))
		if length > 0.2 && length <= 1 do return v / length
	}
}

// A rotation about a random axis, an even scale and a move: what a Transform makes
@(private = "file")
random_model :: proc(r: ^Random) -> Matrix4 {
	axis := random_unit(r)
	angle := next_random(r, 0, 2 * math.PI)
	s, c := math.sin(angle), math.cos(angle)
	k := 1 - c
	scale := next_random(r, 0.5, 2)
	x, y, z := axis.x, axis.y, axis.z
	rotation := Matrix4 {
		{c + x * x * k, x * y * k - z * s, x * z * k + y * s, 0},
		{y * x * k + z * s, c + y * y * k, y * z * k - x * s, 0},
		{z * x * k - y * s, z * y * k + x * s, c + z * z * k, 0},
		{0, 0, 0, 1},
	}
	result := rotation
	for row in 0 ..< 3 {
		for column in 0 ..< 3 do result[row][column] *= scale
		result[row][3] = next_random(r, -2, 2)
	}
	return result
}

// A camera some way off, looking at the origin: right-handed, looking down its -Z, as linalg's look-at
@(private = "file")
random_view :: proc(r: ^Random) -> Matrix4 {
	eye := random_unit(r) * next_random(r, 6, 10)
	forward := unit(-eye)
	right := unit(cross3(forward, {0, 1, 0}))
	up := cross3(right, forward)
	return Matrix4 {
		{right.x, right.y, right.z, -dot3(right, eye)},
		{up.x, up.y, up.z, -dot3(up, eye)},
		{-forward.x, -forward.y, -forward.z, dot3(forward, eye)},
		{0, 0, 0, 1},
	}
}

@(private = "file")
Scene :: struct {
	model, view: Matrix4,
	tint, color: [4]f64,
	shininess, strength: f64,
	ambient: [4]f64,
	direction, diffuse, specular: [8][4]f64,
	place, cone: [8][4]f64, // place.w is the kind: 0 a sun, 1 a point light, 2 a spot
	position, normal: Vector3,
}

@(private = "file")
random_scene :: proc(r: ^Random) -> (scene: Scene) {
	scene.model = random_model(r)
	scene.view = random_view(r)
	for lane in 0 ..< 4 {
		scene.tint[lane] = next_random(r, 0.2, 1)
		scene.color[lane] = next_random(r, 0.2, 1)
		scene.ambient[lane] = next_random(r, 0, 0.3)
	}
	scene.shininess = next_random(r, 1, 64)
	scene.strength = next_random(r, 0, 1)
	count := 1 + int(next_random(r, 0, 7.99))
	for slot in 0 ..< count {
		// unit length, as the engine hands them over (the shader has no instructions to spare to normalize)
		scene.direction[slot].xyz = random_unit(r)
		// a sun, a point light or a spot, the places a few units from the model
		kind := int(next_random(r, 0, 2.999))
		scene.place[slot].xyz = random_unit(r) * next_random(r, 0.5, 8)
		scene.place[slot].w = f64(kind)
		outer := next_random(r, 0.35, 1.25)
		inner := outer * next_random(r, 0, 0.95)
		scale := 1 / max(math.cos(inner) - math.cos(outer), 1e-6)
		scene.cone[slot] = {math.cos(outer), math.cos(inner), scale, -math.cos(outer) * scale}
		for lane in 0 ..< 3 {
			scene.diffuse[slot][lane] = next_random(r, 0, 0.6)
			scene.specular[slot][lane] = next_random(r, 0, 1)
		}
	}
	scene.position = {next_random(r, -1, 1), next_random(r, -1, 1), next_random(r, -1, 1)}
	scene.normal = random_unit(r)
	return
}

// The lighting model, from its description: see the comment at the top of mesh_vertex_lit.mbs
@(private = "file")
calculate_reference_color :: proc(scene: Scene) -> (color: [4]f64) {
	world := multiply(scene.model, {scene.position.x, scene.position.y, scene.position.z, 1})
	eye := multiply(scene.view, world)
	towards_eye := unit(-eye.xyz)
	turned := multiply(scene.view, multiply(scene.model, {scene.normal.x, scene.normal.y, scene.normal.z, 0}))
	normal := unit(turned.xyz)

	diffuse := scene.ambient.xyz
	specular := Vector3{}
	for slot in 0 ..< 8 {
		direction := scene.direction[slot].xyz
		if dot3(direction, direction) == 0 do continue // an empty slot adds nothing
		to_light := direction
		fade := 1.0
		if scene.place[slot].w > 0.5 {
			to := scene.place[slot].xyz - eye.xyz
			distance := math.sqrt(dot3(to, to))
			to_light = unit(to)
			fade = 1 / (1 + 0.09 * distance + 0.032 * distance * distance)
			if scene.place[slot].w > 1.5 {
				// a spot: the smoothstep from the outer cone's cosine to the inner's
				t := clamp((dot3(to_light, direction) - scene.cone[slot][0]) / (scene.cone[slot][1] - scene.cone[slot][0]), 0, 1)
				fade *= t * t * (3 - 2 * t)
			}
		}
		facing := dot3(to_light, normal)
		diffuse += scene.diffuse[slot].xyz * (max(facing, 0) * fade)
		if facing > 0 {
			halfway := unit(to_light + towards_eye)
			specular += scene.specular[slot].xyz * (fade * math.pow(max(dot3(normal, halfway), 1e-8), scene.shininess))
		}
	}
	surface := scene.color * scene.tint
	for lane in 0 ..< 3 {
		lit := clamp(diffuse[lane], 0, 1) * surface[lane] + clamp(specular[lane] * scene.strength, 0, 1)
		color[lane] = clamp(lit, 0, 1)
	}
	color[3] = surface[3]
	return
}

// The scene as the shader's three blocks, each a flat list in the order the shader declares its fields
@(private = "file")
scene_uniforms :: proc(scene: Scene) -> (frame, render, lights: []f32) {
	matrix_numbers :: proc(into: ^[dynamic]f32, m: Matrix4) {
		for row in 0 ..< 4 {
			for column in 0 ..< 4 do append(into, f32(m[row][column]))
		}
	}
	vector_numbers :: proc(into: ^[dynamic]f32, v: [4]f64) {
		for lane in 0 ..< 4 do append(into, f32(v[lane]))
	}
	view_projection := multiply_matrices(Matrix4{{1, 0, 0, 0}, {0, 1, 0, 0}, {0, 0, -0.1, -1}, {0, 0, -1, 0}}, scene.view)

	frame_list := make([dynamic]f32, context.temp_allocator)
	matrix_numbers(&frame_list, view_projection)
	matrix_numbers(&frame_list, scene.view)

	render_list := make([dynamic]f32, context.temp_allocator)
	matrix_numbers(&render_list, scene.model)
	vector_numbers(&render_list, scene.tint)
	vector_numbers(&render_list, {0, 0, 1, 1}) // uv_rectangle
	append(&render_list, 0.5, f32(scene.shininess), f32(scene.strength)) // alpha_cutoff, shininess, strength

	lights_list := make([dynamic]f32, context.temp_allocator)
	vector_numbers(&lights_list, scene.ambient)
	for slot in 0 ..< 8 do vector_numbers(&lights_list, scene.direction[slot])
	for slot in 0 ..< 8 do vector_numbers(&lights_list, scene.diffuse[slot])
	for slot in 0 ..< 8 do vector_numbers(&lights_list, scene.specular[slot])
	for slot in 0 ..< 8 do vector_numbers(&lights_list, scene.place[slot])
	for slot in 0 ..< 8 do vector_numbers(&lights_list, scene.cone[slot])
	return frame_list[:], render_list[:], lights_list[:]
}

@(test)
per_vertex_lighting_matches_the_model :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source, _ := strings.replace_all(#load("../../matchbox/shaders/mesh_vertex_lit.mbs", string), "\r\n", "\n", context.temp_allocator)
	ir, parsed, message := build_ir_for(source, .PICA200)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	program, problems := generate_pica(ir, context.temp_allocator)
	if len(problems) > 0 {
		testing.expectf(t, false, "%v", problems)
		return
	}

	random := Random{state = 20261125}
	worst_interpreter, worst_machine: f64
	for _ in 0 ..< 400 {
		scene := random_scene(&random)
		want := calculate_reference_color(scene)
		frame, render, lights := scene_uniforms(scene)

		interp := Interp{ir = ir, uniforms = make(map[string][]f32, context.temp_allocator)}
		machine := Machine {
			floats = make(map[string][][4]f32, context.temp_allocator),
			bools = make(map[string]bool, context.temp_allocator),
			outputs = make(map[string][4]f32, context.temp_allocator),
		}
		lines := machine_load(&machine, program.vertex)
		for uniform in ir.uniforms {
			flat: []f32
			switch uniform.name {
			case "frame":
				flat = frame
			case "render":
				flat = render
			case "lights":
				flat = lights
			}
			testing.expect_value(t, len(flat), flat_size(ir, uniform.type))
			interp.uniforms[uniform.name] = flat
			fill_leaves(&machine, ir, uniform.name, uniform.type, flat)
		}

		// Vertex_In: position, uv, color, normal
		input := make([dynamic]f32, context.temp_allocator)
		append(&input, f32(scene.position.x), f32(scene.position.y), f32(scene.position.z), 0.25, 0.75)
		for lane in 0 ..< 4 do append(&input, f32(scene.color[lane]))
		append(&input, f32(scene.normal.x), f32(scene.normal.y), f32(scene.normal.z))
		machine.inputs[0] = {f32(scene.position.x), f32(scene.position.y), f32(scene.position.z), 1}
		machine.inputs[1] = {0.25, 0.75, 0, 1}
		for lane in 0 ..< 4 do machine.inputs[2][lane] = f32(scene.color[lane])
		machine.inputs[3] = {f32(scene.normal.x), f32(scene.normal.y), f32(scene.normal.z), 1}

		varying := interp_call(&interp, ir.vertex_main, [][]f32{input[:]})
		machine_run(&machine, lines)
		machine_color := machine.outputs["mbs_out_color"]

		// Varying: position (4), uv (2), color (4)
		for lane in 0 ..< 4 {
			interpreter_color := f64(varying[6 + lane])
			worst_interpreter = max(worst_interpreter, abs(interpreter_color - want[lane]))
			worst_machine = max(worst_machine, abs(f64(machine_color[lane]) - want[lane]))
		}
	}
	// f32 against f64 through a pow of up to 64: a few parts in a hundred thousand. A 3DS colour is 8 bits, 1/255
	testing.expectf(t, worst_interpreter < 1e-4, "the interpreter is %v from the model at worst", worst_interpreter)
	testing.expectf(t, worst_machine < 1e-4, "the PICA program is %v from the model at worst", worst_machine)
	fmt.printfln("per-vertex lighting: worst %.2e (interpreter), %.2e (PICA program) from the f64 model over 400 scenes", worst_interpreter, worst_machine)
}
