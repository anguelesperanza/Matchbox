package matchbox

import "core:math"


/*Vertex used by every mesh*/
Vertex :: struct {
	position:[3]f32,
	uv:[2]f32,
	color:[4]f32,
}


/*A cube centred on the origin, `size` units on each side. Each face has its own colour.
The caller frees both slices (after create_mesh has copied them to the GPU)*/
mesh_cube :: proc(size:f32 = 1, colored:bool = true, allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16) {

	// A face is described by its outward normal, and two axes along it:
	// `u` points right and `v` points up as seen from outside. u x v == normal.
	Face :: struct {
		normal, u, v:[3]f32,
		color:[4]f32,
	}

	faces := [6]Face {
		{{ 0,  0,  1}, { 1,  0,  0}, {0,  1,  0}, {1.0, 0.3, 0.3, 1}}, // +Z, front,  red
		{{ 0,  0, -1}, {-1,  0,  0}, {0,  1,  0}, {0.3, 1.0, 0.3, 1}}, // -Z, back,   green
		{{ 1,  0,  0}, { 0,  0, -1}, {0,  1,  0}, {0.3, 0.3, 1.0, 1}}, // +X, right,  blue
		{{-1,  0,  0}, { 0,  0,  1}, {0,  1,  0}, {1.0, 1.0, 0.3, 1}}, // -X, left,   yellow
		{{ 0,  1,  0}, { 1,  0,  0}, {0,  0, -1}, {0.3, 1.0, 1.0, 1}}, // +Y, top,    cyan
		{{ 0, -1,  0}, { 1,  0,  0}, {0,  0,  1}, {1.0, 0.3, 1.0, 1}}, // -Y, bottom, magenta
	}

	// Four corners per face, counter-clockwise from outside, starting bottom-left
	uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

	// Two triangles per face
	quad_indices := [6]u16{0, 1, 2, 0, 2, 3}

	half := size / 2

	vertices = make([]Vertex, 24, allocator)
	indices = make([]u16, 36, allocator)

	for face, i in faces {
		corners := [4][3]f32 {
			face.normal - face.u - face.v,
			face.normal + face.u - face.v,
			face.normal + face.u + face.v,
			face.normal - face.u + face.v,
		}

		first := i * 4 // index of this face's first vertex

		// White when not colored, so a texture on the cube shows in its own colours
		color := face.color if colored else [4]f32{1, 1, 1, 1}
		for corner, c in corners {
			vertices[first + c] = {position = corner * half, uv = uvs[c], color = color}
		}

		for index, k in quad_indices {
			indices[i * 6 + k] = u16(first) + index
		}
	}

	return
}

/*A square in the XY plane facing +Z, `size` units on each side, centred on the origin.
This is also the shape sprites are drawn with. The caller frees both slices*/
mesh_quad :: proc(size:f32 = 1, color:[4]f32 = {1, 1, 1, 1}, allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16) {
	half := size / 2

	vertices = make([]Vertex, 4, allocator)
	indices = make([]u16, 6, allocator)

	vertices[0] = {position = {-half, -half, 0}, uv = {0, 1}, color = color} // bottom left
	vertices[1] = {position = { half, -half, 0}, uv = {1, 1}, color = color} // bottom right
	vertices[2] = {position = { half,  half, 0}, uv = {1, 0}, color = color} // top right
	vertices[3] = {position = {-half,  half, 0}, uv = {0, 0}, color = color} // top left

	indices[0], indices[1], indices[2] = 0, 1, 2
	indices[3], indices[4], indices[5] = 0, 2, 3

	return
}

/*A right triangle with corners (0,0), (1,0) and (0,1). render_triangle maps it onto any three points*/
mesh_triangle :: proc(allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16) {
	vertices = make([]Vertex, 3, allocator)
	indices = make([]u16, 3, allocator)

	white := [4]f32{1, 1, 1, 1}
	vertices[0] = {position = {0, 0, 0}, uv = {0, 1}, color = white}
	vertices[1] = {position = {1, 0, 0}, uv = {1, 1}, color = white}
	vertices[2] = {position = {0, 1, 0}, uv = {0, 0}, color = white}

	indices[0], indices[1], indices[2] = 0, 1, 2
	return
}

/*A circle of radius 1 centred on the origin, as a fan of `segments` triangles*/
mesh_circle :: proc(segments:int = 48, allocator := context.allocator) -> (vertices:[]Vertex, indices:[]u16) {
	assert(segments >= 3 && segments <= 65534, "A circle needs 3 to 65534 segments")

	vertices = make([]Vertex, segments + 1, allocator)
	indices = make([]u16, segments * 3, allocator)

	white := [4]f32{1, 1, 1, 1}
	vertices[0] = {position = {0, 0, 0}, uv = {0.5, 0.5}, color = white} // centre

	for i in 0..<segments {
		angle := f32(i) / f32(segments) * 2 * math.PI
		x := math.cos(angle)
		y := math.sin(angle)

		vertices[i + 1] = {position = {x, y, 0}, uv = {x * 0.5 + 0.5, 0.5 - y * 0.5}, color = white}

		next := (i + 1) % segments
		indices[i * 3 + 0] = 0
		indices[i * 3 + 1] = u16(i + 1)
		indices[i * 3 + 2] = u16(next + 1)
	}
	return
}
