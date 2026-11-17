// hit_flash.shader
//
// FAKE. This file does nothing: the compiler (Phase S) doesn't exist yet and
// every piece of syntax below is a draft. It is here to show the shape of a
// Matchbox shader. The extension (.shader) is a placeholder.
//
// What it does: draws a textured, tinted sprite or mesh, and can flash it
// toward white (the "I just got hit" effect). `flash` is 0 for normal and 1
// for solid white, and it pulses a little.

// What a vertex looks like coming from the mesh. The tags say which vertex
// attribute each field reads from; they match Matchbox's Vertex struct.
Vertex_In :: struct {
	position: [3]f32 `attr:"position"`,
	uv:       [2]f32 `attr:"texcoord"`,
	color:    [4]f32 `attr:"color"`,
}

// What the vertex stage hands to the fragment stage
Varying :: struct {
	position: [4]f32 `out:"position"`, // clip-space position (required)
	uv:       [2]f32 `out:"texcoord"`,
	color:    [4]f32 `out:"color"`,
}

// ---- Values the engine fills in. A shader just declares them. ----

@(uniform = .FRAME) frame: struct {
	view_projection: matrix[4, 4]f32,
	time:            f32, // seconds
}

@(uniform = .DRAW) draw: struct {
	model: matrix[4, 4]f32,
	tint:  [4]f32,
}

// ---- Values the game sets: mb.set_shader_value(shader, "flash", 0.5) ----

@(uniform) flash: f32 // 0 = normal, 1 = solid white

@(texture = 0) albedo: Texture2D

// A helper procedure. Plain Odin-style code.
// The 3DS has no sin(), so there the pulse is a constant instead.
pulse :: proc(time: f32) -> f32 {
	when TARGET == .PICA200 {
		return 1
	} else {
		return 0.75 + 0.25 * sin(time * 8)
	}
}

vertex_main :: proc(in: Vertex_In) -> Varying {
	out: Varying

	position := [4]f32{in.position.x, in.position.y, in.position.z, 1}
	out.position = frame.view_projection * draw.model * position

	out.uv    = in.uv
	out.color = in.color * draw.tint
	return out
}

fragment_main :: proc(v: Varying) -> [4]f32 {
	texel := sample(albedo, v.uv)
	color := texel * v.color

	// Move the colour toward white by `flash`. The alpha is left alone.
	color.rgb = mix(color.rgb, [3]f32{1, 1, 1}, flash * pulse(frame.time))

	return color
}
