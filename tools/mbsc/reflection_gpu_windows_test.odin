package mbsc

import "core:strings"
import "core:testing"

// Values written at the offsets of the reflection file, read back by a shader on Direct3D's software device. The
// layout test compares offsets with d3dcompiler's answer; this one shows the numbers arrive where the shader
// reads them, matrices and arrays and structs included.

@(private = "file")
Probe_Setup :: struct {
	layout: Layout,
	values: []f32, // the game buffer, a float at a time
}

@(private = "file")
find_entry :: proc(layout: Layout, name: string) -> Layout_Entry {
	for entry in layout.entries {
		if entry.name == name {
			return entry
		}
	}
	panic("no such uniform in the test shader")
}

// put writes floats at the start of a uniform; `element` picks an element of an array.
@(private = "file")
put :: proc(setup: Probe_Setup, name: string, numbers: []f32, element := 0) {
	entry := find_entry(setup.layout, name)
	start := (entry.offset + element * entry.stride) / 4
	copy(setup.values[start:], numbers)
}

// put_matrix writes the way the engine does: column c at 16 * c, a row after another inside it. `at(row, column)` is
// the number that goes in that place.
@(private = "file")
put_matrix :: proc(setup: Probe_Setup, name: string, rows, columns: int, element := 0, scale: f32 = 1) {
	entry := find_entry(setup.layout, name)
	start := (entry.offset + element * entry.stride) / 4
	for column in 0 ..< columns {
		for row in 0 ..< rows {
			setup.values[start + column * 4 + row] = scale * f32(row * 10 + column + 1)
		}
	}
}

// The engine's blocks for a draw that changes nothing: the vertex stage then puts the triangle where it is given.
@(private = "file")
identity_frame :: proc() -> []f32 {
	values := make([]f32, 20, context.temp_allocator)
	copy(values, []f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1})
	return values
}

@(private = "file")
identity_render :: proc() -> []f32 {
	values := make([]f32, 28, context.temp_allocator)
	copy(values, []f32{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1})
	return values
}

// probe renders the uniforms shader with a fragment stage that returns `expression`.
@(private = "file")
probe :: proc(source: string, expression: string, setup: Probe_Setup) -> (result: [4]f32, message: string) {
	replaced, _ := strings.replace(source, "return sample(albedo, v.uv) * sample(mask, v.uv).x * render.tint * flash", strings.concatenate({"return ", expression}, context.temp_allocator), 1, context.temp_allocator)
	hlsl, hlsl_message := mbs_to_hlsl_for_probe(replaced)
	if hlsl_message != "" {
		return {}, hlsl_message
	}
	vertices := [?]f32{-1, -1, 0, 0, 0, 0, 0, 0, 0, 3, -1, 0, 0, 0, 0, 0, 0, 0, -1, 3, 0, 0, 0, 0, 0, 0, 0}
	indices := [?]u16{0, 1, 2}
	pixels, render_message := gpu_render(
		Gpu_Job {
			hlsl = hlsl,
			vertex_entry = "vertex_main",
			pixel_entry = "fragment_main",
			width = 1,
			height = 1,
			vertices = vertices[:],
			indices = indices[:],
			frame = identity_frame(),
			draw = identity_render(),
			game = setup.values,
		},
	)
	if render_message != "" {
		return {}, render_message
	}
	return pixel_at(pixels, 1, 0, 0), ""
}

@(private = "file")
mbs_to_hlsl_for_probe :: proc(source: string) -> (text: string, message: string) {
	ir, parsed, build_message := build_ir(source)
	defer destroy_parsed(parsed)
	if build_message != "" {
		return "", build_message
	}
	problems: []string
	text, problems = generate_hlsl(ir, context.temp_allocator)
	if len(problems) > 0 {
		return "", strings.join(problems, "\n", context.temp_allocator)
	}
	return text, ""
}

@(private = "file")
expect_all :: proc(t: ^testing.T, what: string, got, want: [4]f32, loc := #caller_location) {
	for part in 0 ..< 4 {
		testing.expectf(t, abs(got[part] - want[part]) <= 1e-6, "%s: component %d is %v, want %v", what, part, got[part], want[part], loc = loc)
	}
}

@(test)
values_written_at_the_reflected_offsets_are_what_the_shader_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	source, _ := strings.replace_all(string(#load("testdata/uniforms.mbs", string)), "\r\n", "\n", context.temp_allocator)
	ir, parsed, message := build_ir(source)
	defer destroy_parsed(parsed)
	if message != "" {
		testing.expect(t, false, message)
		return
	}
	layout := game_layout(ir)
	setup := Probe_Setup {
		layout = layout,
		values = make([]f32, layout.size / 4, context.temp_allocator),
	}

	// scalars and vectors that share registers
	put(setup, "flash", {0.5})
	put(setup, "offset", {1, 2, 3})
	put(setup, "amount", {9})
	put(setup, "pair", {4, 5})
	put(setup, "triple", {6, 7, 8})
	put(setup, "wide", {10, 11, 12, 13})
	got, probe_message := probe(source, "[4]f32{flash, offset.x + offset.z, amount, pair.y}", setup)
	if probe_message != "" {
		testing.expect(t, false, probe_message)
		return
	}
	expect_all(t, "scalars and vectors", got, {0.5, 4, 9, 5})

	got, _ = probe(source, "[4]f32{triple.z, wide.w, offset.y, pair.x}", setup)
	expect_all(t, "vectors after vectors", got, {8, 13, 2, 4})

	// matrices go in by columns: a matrix times (0, 1, 0) is its second column
	put_matrix(setup, "rotation", 3, 3)
	put_matrix(setup, "small", 2, 2)
	put_matrix(setup, "skew", 3, 4)
	put_matrix(setup, "tall", 4, 3)
	got, _ = probe(source, "[4]f32{(rotation * [3]f32{0.0, 1.0, 0.0}).z, (small * [2]f32{0.0, 1.0}).y, (skew * [4]f32{0.0, 0.0, 0.0, 1.0}).y, (tall * [3]f32{0.0, 0.0, 1.0}).w}", setup)
	// the number at [row, column] is row * 10 + column + 1: rotation[2, 1] = 22, small[1, 1] = 12, skew[1, 3] = 14, tall[3, 2] = 33
	expect_all(t, "matrices", got, {22, 12, 14, 33})

	// arrays: each element 16 bytes on from the one before
	for index in 0 ..< 5 {
		put(setup, "weights", {f32(index) + 100}, index)
	}
	for index in 0 ..< 3 {
		put(setup, "directions", {f32(index), f32(index) + 0.25, f32(index) + 0.5}, index)
	}
	for index in 0 ..< 4 {
		put(setup, "palette", {f32(index), f32(index) * 2, f32(index) * 3, f32(index) * 4}, index)
	}
	put_matrix(setup, "bones", 4, 4, 0)
	put_matrix(setup, "bones", 4, 4, 1, 100)
	got, _ = probe(source, "[4]f32{weights[3], directions[2].y, palette[3].w, (bones[1] * [4]f32{0.0, 0.0, 1.0, 0.0}).w}", setup)
	// weights[3] = 103, directions[2].y = 2.25, palette[3].w = 12, bones[1][3, 2] = 100 * 33
	expect_all(t, "arrays", got, {103, 2.25, 12, 3300})

	// structs, nested structs, arrays of structs, and a plain value straight after one
	put(setup, "key_light.direction", {1, 2, 3})
	put(setup, "key_light.strength", {4})
	put(setup, "key_light.color", {5, 6, 7})
	put(setup, "trailing", {8})
	put(setup, "rig.key.color", {9, 10, 11})
	put(setup, "rig.scale", {12})
	put(setup, "rig.fill.direction", {13, 14, 15})
	put(setup, "rig.fill.strength", {16})
	put(setup, "lights[0].strength", {17})
	put(setup, "lights[1].direction", {18, 19, 20})
	put(setup, "lights[1].color", {21, 22, 23})
	put(setup, "last", {24, 25})
	got, _ = probe(source, "[4]f32{key_light.strength + key_light.color.z, trailing + rig.key.color.y + rig.scale, rig.fill.direction.y + rig.fill.strength + lights[0].strength, lights[1].direction.z + lights[1].color.x + last.y}", setup)
	expect_all(t, "structs", got, {4 + 7, 8 + 10 + 12, 14 + 16 + 17, 20 + 21 + 25})
}
