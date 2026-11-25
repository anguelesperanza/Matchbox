package matchbox

import "core:math"


/*Vertex used by sprites, shapes and text: what an unlit draw reads (36 bytes)*/
Vertex :: struct {
	position:[3]f32,
	uv:[2]f32,
	color:[4]f32,
}

/*
	Vertex used by models: a Vertex and the normal lighting needs (48 bytes, G2 L4-2). Kept
	apart from Vertex so 2D, which never lights, uploads no normals. Vertex comes first, whole,
	so `v.position` still reads and the first 36 bytes are laid out as a Vertex's: the unlit
	shaders' input layout reads a lit mesh unchanged, given the longer stride. A normal is unit
	length, in the model's own space
*/
Lit_Vertex :: struct {
	using vertex:Vertex,
	normal:[3]f32,
}


/*A cube centred on the origin, `size` units on each side. Each face has its own colour, and its own
vertices so each corner carries that face's normal. The caller frees both slices (after
create_lit_mesh has copied them to the GPU)*/
mesh_cube :: proc(size:f32 = 1, colored:bool = true, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16) {

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

	vertices = make([]Lit_Vertex, 24, allocator)
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
			vertices[first + c] = {vertex = {position = corner * half, uv = uvs[c], color = color}, normal = face.normal}
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

/*
	A flat square of `size` units on the ground plane (x and z), facing up: the same four
	corners as the cube's top face, wound the same way. The caller frees both slices
*/
mesh_plane :: proc(size:f32 = 1, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16) {
	half := size * 0.5
	white := [4]f32{1, 1, 1, 1}
	up := [3]f32{0, 1, 0}
	vertices = make([]Lit_Vertex, 4, allocator)
	indices = make([]u16, 6, allocator)
	vertices[0] = {vertex = {position = {-half, 0, half}, uv = {0, 1}, color = white}, normal = up}
	vertices[1] = {vertex = {position = {half, 0, half}, uv = {1, 1}, color = white}, normal = up}
	vertices[2] = {vertex = {position = {half, 0, -half}, uv = {1, 0}, color = white}, normal = up}
	vertices[3] = {vertex = {position = {-half, 0, -half}, uv = {0, 0}, color = white}, normal = up}
	indices[0], indices[1], indices[2] = 0, 1, 2
	indices[3], indices[4], indices[5] = 0, 2, 3
	return
}

/*
	A sphere of `radius`, in rings of latitude and sectors of longitude, wound counter-clockwise
	from outside. Both loops run to `<=` their count, so the seam where longitude wraps has two
	vertices in the same place with different uvs: otherwise the last sector would stretch the
	whole texture back across itself. The normal is the direction from the centre, so the
	shading is round however coarse the rings are. The caller frees both slices
*/
mesh_sphere :: proc(radius:f32 = 1, rings:int = 16, sectors:int = 24, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16) {
	rings := max(rings, 2)
	sectors := max(sectors, 3)
	assert((rings + 1) * (sectors + 1) <= 65536, "A sphere this fine needs more than 16-bit indices")
	vertices = make([]Lit_Vertex, (rings + 1) * (sectors + 1), allocator)
	indices = make([]u16, rings * sectors * 6, allocator)

	for ring in 0 ..= rings {
		phi := math.PI * f32(ring) / f32(rings) // 0 at the top, pi at the bottom
		y := math.cos(phi)
		ring_radius := math.sin(phi)
		for sector in 0 ..= sectors {
			theta := 2 * math.PI * f32(sector) / f32(sectors)
			direction := [3]f32{ring_radius * math.cos(theta), y, ring_radius * math.sin(theta)}
			vertices[ring * (sectors + 1) + sector] = Lit_Vertex {
				vertex = {
					position = direction * radius,
					uv = {f32(sector) / f32(sectors), f32(ring) / f32(rings)},
					color = {1, 1, 1, 1},
				},
				normal = direction,
			}
		}
	}
	next := 0
	for ring in 0 ..< rings {
		for sector in 0 ..< sectors {
			a := u16(ring * (sectors + 1) + sector)
			b := a + u16(sectors + 1)
			indices[next + 0], indices[next + 1], indices[next + 2] = a, a + 1, b
			indices[next + 3], indices[next + 4], indices[next + 5] = a + 1, b + 1, b
			next += 6
		}
	}
	return
}

/*
	A cylinder of `radius` and `height`, upright about Y and centred on its own origin, wound
	counter-clockwise from outside. The side and the two caps share no vertices: a shared rim
	vertex would have to average a cap's normal and the side's, and light the edge as if it
	were rounded off. The caller frees both slices
*/
mesh_cylinder :: proc(radius:f32 = 0.5, height:f32 = 1, sectors:int = 24, allocator := context.allocator) -> (vertices:[]Lit_Vertex, indices:[]u16) {
	sectors := max(sectors, 3)
	half := height * 0.5
	white := [4]f32{1, 1, 1, 1}
	up := [3]f32{0, 1, 0}
	down := [3]f32{0, -1, 0}

	// The side: two rings of sectors + 1. Each cap: a middle vertex and a ring of sectors
	side_count := (sectors + 1) * 2
	vertices = make([]Lit_Vertex, side_count + (sectors + 1) * 2, allocator)
	indices = make([]u16, sectors * 12, allocator)

	for sector in 0 ..= sectors {
		theta := 2 * math.PI * f32(sector) / f32(sectors)
		outward := [3]f32{math.cos(theta), 0, math.sin(theta)}
		x, z := outward.x * radius, outward.z * radius
		u := f32(sector) / f32(sectors)
		vertices[sector] = {vertex = {position = {x, half, z}, uv = {u, 0}, color = white}, normal = outward}
		vertices[sectors + 1 + sector] = {vertex = {position = {x, -half, z}, uv = {u, 1}, color = white}, normal = outward}
	}

	top_middle := side_count
	bottom_middle := side_count + sectors + 1
	vertices[top_middle] = {vertex = {position = {0, half, 0}, uv = {0.5, 0.5}, color = white}, normal = up}
	vertices[bottom_middle] = {vertex = {position = {0, -half, 0}, uv = {0.5, 0.5}, color = white}, normal = down}
	for sector in 0 ..< sectors {
		theta := 2 * math.PI * f32(sector) / f32(sectors)
		x, z := math.cos(theta), math.sin(theta)
		uv := [2]f32{x * 0.5 + 0.5, z * 0.5 + 0.5}
		vertices[top_middle + 1 + sector] = {vertex = {position = {x * radius, half, z * radius}, uv = uv, color = white}, normal = up}
		vertices[bottom_middle + 1 + sector] = {vertex = {position = {x * radius, -half, z * radius}, uv = uv, color = white}, normal = down}
	}

	next := 0
	for sector in 0 ..< sectors {
		top := u16(sector)
		bottom := u16(sectors + 1 + sector)
		indices[next + 0], indices[next + 1], indices[next + 2] = top, bottom + 1, bottom
		indices[next + 3], indices[next + 4], indices[next + 5] = top, top + 1, bottom + 1
		next += 6
	}
	for sector in 0 ..< sectors {
		following := (sector + 1) % sectors
		// Seen from above the top ring runs clockwise in x and z, so its fan is middle, next,
		// sector to come out counter-clockwise from outside; the bottom, seen from below, is
		// the other way round
		indices[next + 0], indices[next + 1], indices[next + 2] = u16(top_middle), u16(top_middle + 1 + following), u16(top_middle + 1 + sector)
		indices[next + 3], indices[next + 4], indices[next + 5] = u16(bottom_middle), u16(bottom_middle + 1 + sector), u16(bottom_middle + 1 + following)
		next += 6
	}
	return
}
