package matchbox

/*
	Model
	-----
	Geometry that lives on the GPU, and the first thing in Matchbox to own a
	vertex buffer of its own. Everything in 2D draws the one shared quad; a
	model is the case that could not.

	The name is `Model` and not `Mesh` because `Mesh` is already the texture
	holder that `Sprite` embeds -- see D6 in 3d.md. A Model is what one file
	loads into: several parts, each with its own geometry and its own material,
	because a glTF scene routinely has more than one of both.

	Stage 1 generates models in code and every part is untextured. Stage 4 adds
	the loader, which is why the part already has room for a texture nothing
	fills in yet.
*/

import "core:math"

import sdl "vendor:sdl3"

/*
	Whether a part's indices describe filled triangles or bare lines.

	The zero value is triangles, so everything written before wireframes existed
	still means what it did. A part carries this rather than a Model, because
	a loaded file could reasonably hold both -- and because it is the pipeline
	selector, and pipelines are chosen per draw.
*/
Mesh_Topology :: enum {
	TRIANGLES,
	LINES,
}

/*
	One buffer of geometry with one material.

	`index_count` rather than a slice: the vertices are on the GPU by the time
	this exists and the CPU copy is gone, so the count is the only thing left
	that says how much to draw.
*/
Model_Part :: struct {
	vertices:    ^sdl.GPUBuffer,
	indices:     ^sdl.GPUBuffer,
	index_count: u32,
	topology:    Mesh_Topology,

	// Filled in by the loader in stage 4. A part with no texture is drawn by
	// the flat pipeline in its tint alone.
	texture:     ^sdl.GPUTexture,
	sampler:     ^sdl.GPUSampler,
}

/*
	A whole model, as one file or one generator produced it.

	`bounds_min` / `bounds_max` are the model's own extents in its own space,
	worked out once while the vertex data is in hand. It is not a collision
	feature -- Matchbox has none, see D7 -- it is what a game measures a
	`b3.MakeBoxHull` from, and what `draw_box_wires` is pointed at to see the
	thing it just loaded.
*/
Model :: struct {
	parts:      []Model_Part,
	bounds_min: [3]f32,
	bounds_max: [3]f32,
}

// The middle of the model's own bounds, and how big it is. What a game hands to
// a physics library, which wants a centre and half-extents rather than corners.
model_center :: proc(model: Model) -> [3]f32 {
	return (model.bounds_min + model.bounds_max) * 0.5
}

model_size :: proc(model: Model) -> [3]f32 {
	return model.bounds_max - model.bounds_min
}

/*
	Puts one lump of geometry on the GPU.

	Both buffers go through the same staging path everything else uses, so a
	part costs two copy passes at load and nothing afterwards. The slices belong
	to the caller and are not kept.
*/
upload_mesh :: proc(vertices: []Vertex3D, indices: []u32, topology := Mesh_Topology.TRIANGLES) -> Model_Part {
	ensure(len(vertices) > 0, "a mesh needs vertices")
	ensure(len(indices) > 0, "a mesh needs indices")

	return Model_Part{
		vertices    = upload_buffer(raw_data(vertices), u32(len(vertices) * size_of(Vertex3D)), {.VERTEX}),
		indices     = upload_buffer(raw_data(indices),  u32(len(indices)  * size_of(u32)),      {.INDEX}),
		index_count = u32(len(indices)),
		topology    = topology,
	}
}

// A model of one part, from one lump of geometry. Bounds are measured off the
// vertices on the way past, since they are right here and will not be later.
model_from_mesh :: proc(vertices: []Vertex3D, indices: []u32, topology := Mesh_Topology.TRIANGLES) -> Model {
	parts := make([]Model_Part, 1)
	parts[0] = upload_mesh(vertices, indices, topology)

	low  := vertices[0].pos
	high := vertices[0].pos
	for v in vertices[1:] {
		low  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
		high = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
	}

	return Model{parts = parts, bounds_min = low, bounds_max = high}
}

destroy_model :: proc(model: ^Model) {
	device := mbi.renderer.device
	if device == nil do return

	for &part in model.parts {
		if part.vertices != nil do sdl.ReleaseGPUBuffer(device, part.vertices)
		if part.indices  != nil do sdl.ReleaseGPUBuffer(device, part.indices)

		// The texture is the part's own once stage 4's loader makes one. A
		// texture shared with something else does not belong here, which is why
		// the loader will be the only thing that sets it.
		if part.texture != nil do sdl.ReleaseGPUTexture(device, part.texture)

		part.vertices = nil
		part.indices  = nil
		part.texture  = nil
	}

	delete(model.parts)
	model.parts = nil
}

// -----------------------------------------------------------------------
// Generated geometry
// -----------------------------------------------------------------------

/*
	A cube of `size` units, centred on its own origin.

	Twenty-four vertices for six faces rather than eight shared corners: a
	shared corner would have to average the normals of the three faces meeting
	there, which rounds the edges off a shape whose whole character is that they
	are sharp.

	Wound counter-clockwise seen from outside, which is what the pipeline's
	`front_face` expects and what glTF produces.
*/
cube_model :: proc(size: f32 = 1) -> Model {
	h := size * 0.5

	// Per face: the four corners in counter-clockwise order seen from outside,
	// and the direction the face points.
	Face :: struct {
		corners: [4][3]f32,
		normal:  [3]f32,
	}

	faces := [6]Face{
		{{{-h, -h,  h}, { h, -h,  h}, { h,  h,  h}, {-h,  h,  h}}, { 0,  0,  1}}, // front
		{{{ h, -h, -h}, {-h, -h, -h}, {-h,  h, -h}, { h,  h, -h}}, { 0,  0, -1}}, // back
		{{{ h, -h,  h}, { h, -h, -h}, { h,  h, -h}, { h,  h,  h}}, { 1,  0,  0}}, // right
		{{{-h, -h, -h}, {-h, -h,  h}, {-h,  h,  h}, {-h,  h, -h}}, {-1,  0,  0}}, // left
		{{{-h,  h,  h}, { h,  h,  h}, { h,  h, -h}, {-h,  h, -h}}, { 0,  1,  0}}, // top
		{{{-h, -h, -h}, { h, -h, -h}, { h, -h,  h}, {-h, -h,  h}}, { 0, -1,  0}}, // bottom
	}

	uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

	vertices := make([]Vertex3D, 24, context.temp_allocator)
	indices  := make([]u32,      36, context.temp_allocator)

	for face, f in faces {
		base := u32(f) * 4

		for corner, c in face.corners {
			vertices[int(base) + c] = Vertex3D{
				pos    = corner,
				normal = face.normal,
				uv     = uvs[c],
			}
		}

		i := f * 6
		indices[i + 0] = base + 0
		indices[i + 1] = base + 1
		indices[i + 2] = base + 2
		indices[i + 3] = base + 0
		indices[i + 4] = base + 2
		indices[i + 5] = base + 3
	}

	return model_from_mesh(vertices, indices)
}

/*
	A flat square of `size` units on the ground plane, facing up.

	The same four corners as the cube's top face, wound the same way, so a plane
	and the top of a cube agree about which side is out.
*/
plane_model :: proc(size: f32 = 1) -> Model {
	h := size * 0.5

	vertices := []Vertex3D{
		{pos = {-h, 0,  h}, normal = {0, 1, 0}, uv = {0, 1}},
		{pos = { h, 0,  h}, normal = {0, 1, 0}, uv = {1, 1}},
		{pos = { h, 0, -h}, normal = {0, 1, 0}, uv = {1, 0}},
		{pos = {-h, 0, -h}, normal = {0, 1, 0}, uv = {0, 0}},
	}

	indices := []u32{0, 1, 2, 0, 2, 3}

	return model_from_mesh(vertices, indices)
}

/*
	A sphere of `radius`, built the usual way out of rings of latitude and
	sectors of longitude.

	The defaults are a shape smooth enough to read as round and cheap enough to
	scatter a hundred of. A normal here is just the direction from the centre,
	which is the one case where the normal falls out of the position for free.

	Both loops run to `<=` their count, so the seam where longitude wraps has
	two vertices at the same place with different uvs -- otherwise the last
	sector would stretch the whole texture backwards across itself.
*/
sphere_model :: proc(radius: f32 = 1, rings: int = 16, sectors: int = 24) -> Model {
	rings   := max(rings, 2)
	sectors := max(sectors, 3)

	vertices := make([]Vertex3D, (rings + 1) * (sectors + 1), context.temp_allocator)
	indices  := make([dynamic]u32, 0, rings * sectors * 6, context.temp_allocator)

	for r in 0 ..= rings {
		phi := math.PI * f32(r) / f32(rings) // 0 at the top, pi at the bottom
		y   := math.cos(phi)
		ring_radius := math.sin(phi)

		for s in 0 ..= sectors {
			theta := 2 * math.PI * f32(s) / f32(sectors)

			normal := [3]f32{ring_radius * math.cos(theta), y, ring_radius * math.sin(theta)}

			vertices[r * (sectors + 1) + s] = Vertex3D{
				pos    = normal * radius,
				normal = normal,
				uv     = {f32(s) / f32(sectors), f32(r) / f32(rings)},
			}
		}
	}

	for r in 0 ..< rings {
		for s in 0 ..< sectors {
			a := u32(r * (sectors + 1) + s)
			b := a + u32(sectors + 1)

			append(&indices, a, a + 1, b)
			append(&indices, a + 1, b + 1, b)
		}
	}

	return model_from_mesh(vertices, indices[:])
}

// -----------------------------------------------------------------------
// Generated geometry -- lines
// -----------------------------------------------------------------------

/*
	The twelve edges of a cube, as lines.

	Eight vertices rather than the solid cube's twenty-four: an edge has no
	face, so there are no normals to disagree about and the corners can be
	shared. The normals are filled in anyway because the vertex layout is shared
	with the solid pipeline -- the line shader ignores them.
*/
cube_wires_model :: proc(size: f32 = 1) -> Model {
	h := size * 0.5

	corners := [8][3]f32{
		{-h, -h, -h}, { h, -h, -h}, { h, -h,  h}, {-h, -h,  h}, // bottom, anticlockwise
		{-h,  h, -h}, { h,  h, -h}, { h,  h,  h}, {-h,  h,  h}, // top, the same way round
	}

	vertices := make([]Vertex3D, 8, context.temp_allocator)
	for corner, i in corners {
		vertices[i] = Vertex3D{pos = corner, normal = {0, 1, 0}, uv = {0, 0}}
	}

	indices := []u32{
		0, 1, 1, 2, 2, 3, 3, 0, // bottom
		4, 5, 5, 6, 6, 7, 7, 4, // top
		0, 4, 1, 5, 2, 6, 3, 7, // the uprights joining them
	}

	return model_from_mesh(vertices, indices, .LINES)
}

/*
	A grid of lines on the ground plane, centred on the origin.

	`slices` squares across and the same again deep, each `spacing` units on a
	side. `draw_grid` keeps one of these and rebuilds it only when the numbers
	change, so a game asking for the same grid every frame builds it once.
*/
grid_model :: proc(slices: int = 10, spacing: f32 = 1) -> Model {
	slices := max(slices, 1)

	half  := f32(slices) * spacing * 0.5
	count := slices + 1

	vertices := make([]Vertex3D, count * 4, context.temp_allocator)
	indices  := make([]u32,      count * 4, context.temp_allocator)

	for i in 0 ..< count {
		offset := -half + f32(i) * spacing
		v      := i * 4

		// One line along z, one along x, so a single pass lays both directions.
		vertices[v + 0] = Vertex3D{pos = {offset, 0, -half}, normal = {0, 1, 0}}
		vertices[v + 1] = Vertex3D{pos = {offset, 0,  half}, normal = {0, 1, 0}}
		vertices[v + 2] = Vertex3D{pos = {-half,  0, offset}, normal = {0, 1, 0}}
		vertices[v + 3] = Vertex3D{pos = { half,  0, offset}, normal = {0, 1, 0}}

		indices[v + 0] = u32(v + 0)
		indices[v + 1] = u32(v + 1)
		indices[v + 2] = u32(v + 2)
		indices[v + 3] = u32(v + 3)
	}

	return model_from_mesh(vertices, indices, .LINES)
}
