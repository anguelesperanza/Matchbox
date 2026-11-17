package matchbox


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

		for corner, c in corners {
			vertices[first + c] = {position = corner * half, uv = uvs[c], color = face.color}

			color:[4]f32 = face.color
			if colored == false do color = {1,1,1,1}
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
