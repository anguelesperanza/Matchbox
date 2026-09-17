
package matchbox

/*
	Model
	-----
	Geometry that lives on the GPU, and the first thing in Matchbox to own a
	vertex buffer of its own. Everything in 2D draws the one shared quad; a
	model is the case that could not.

	The name is `Model` and not `Mesh` because `Mesh` is already the texture
	holder that `Sprite` embeds. A Model is what one file
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

	/*
		What this part is made of. `MATERIAL_DEFAULTS` (material.odin) for
		everything generated in code and for a glTF part with no material at
		all -- lit, white, Blinn-Phong -- and for one that has a material,
		`read_material` (model_load.odin)'s full reading of it: base colour,
		metallic-roughness, occlusion and emissive, factors and textures
		alike. A part missing any one of those textures is drawn with the 1x1
		white default `init` makes for exactly that -- see `render3d.odin` --
		rather than a separate untextured pipeline the way it was before this
		rework.
	*/
	material: Material,

	/*
		Which skin deforms this part, and which node its mesh hangs off. `skin`
		is -1 for everything that is not skinned, which is every cube, every
		plane, and every part of every model that has no skeleton.

		A skinned part's vertices are `Vertex3D_Skinned` rather than `Vertex3D`
		and go through their own pipeline, so this is what the draw call
		switches on. `node` is only read to complete glTF's joint matrix
		formula -- see `animator_resolve`.
	*/
	skin:        int,
	node:        u32,

	/*
		Which of the skin's joints this part actually uses, in the order its
		vertices name them. A vertex's `joints` index into *this*, not into the
		skin -- so a part touching 37 of a rig's 66 joints carries a palette 37
		long and never names an index above 36.

		Originally forced by a 4096-byte Vulkan uniform ceiling of exactly 64
		matrices; the palette is a storage buffer now and that ceiling is gone
		(see `joint_offset` and `refactor.md`'s "storage buffer" note), but the
		compacting stays. It is still a real memory saving -- this character has
		66 joints in its skin and no primitive using more than 37 of them -- and
		costs nothing now that nothing is dropped to make it fit.
	*/
	joint_map:    []u32,

	/*
		Where this part's palette starts in its animator's joint buffer, in
		matrices. Every part of a model shares one buffer -- one upload, one
		bind, per character per frame, rather than one of each per part -- and
		this is the offset that tells the shader which slice is this part's.

		A property of the model, computed once at load as a running sum over
		`parts` in order, not of any one animator: two animators of the same
		model agree on it without either being asked.
	*/
	joint_offset: u32,
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

	// Empty unless the file carried a skin. See `animation3d.odin` -- the
	// skeleton is the rest pose and the hierarchy, the animations are the
	// clips, and neither changes once loaded. What moves is an `Animator`.
	skeleton:   Skeleton,
	animations: []Model_Animation,

	// The zero value for a file with no `humanoid` block, the same way
	// `skeleton` and `animations` are "empty unless the file had one" -- see
	// `vrm.odin`. What this holds is a *reading* of the file's own map from a
	// spec-defined role to a node in `skeleton`, nothing more: it costs
	// nothing to carry on a model that never asks `vrm_bone` a question.
	vrm_humanoid: Vrm_Humanoid,

	// The sum of every part's `joint_map`, i.e. how many matrices one
	// animator's joint buffer holds for this model. 0 for a model with no
	// skin. Computed alongside `joint_offset`, for the same reason: it is the
	// model's own number, not any one animator's.
	total_joints: int,
}

// The middle of the model's own bounds, and how big it is. What a game hands to
// a physics library, which wants a centre and half-extents rather than corners.
model_center :: proc(model: Model) -> [3]f32 {
	return (model.bounds_min + model.bounds_max) * 0.5
}

// How big the model is on each axis, in its own space before any Transform.
// What a game scales from, and what sizes a collider to match the art.
model_size :: proc(model: Model) -> [3]f32 {
	return model.bounds_max - model.bounds_min
}

/*
	Puts one lump of geometry on the GPU.

	Both buffers go through the same staging path everything else uses, so a
	part costs two copy passes at load and nothing afterwards. The slices belong
	to the caller and are not kept.
*/
upload_mesh :: proc(vertices: []Vertex3D, indices: []u32, topology := Mesh_Topology.TRIANGLES) -> (Model_Part, Error) {
	if len(vertices) == 0 || len(indices) == 0 do return {}, Argument_Error.No_Geometry

	vertex_buffer, vertex_err := upload_buffer(raw_data(vertices), u32(len(vertices) * size_of(Vertex3D)), {.VERTEX})
	if vertex_err != nil do return {}, vertex_err

	// The vertices are already on the device, so a failure here has something
	// to give back rather than only something to report.
	index_buffer, index_err := upload_buffer(raw_data(indices), u32(len(indices) * size_of(u32)), {.INDEX})
	if index_err != nil {
		sdl.ReleaseGPUBuffer(mbi.renderer.device, vertex_buffer)
		return {}, index_err
	}

	return Model_Part{
		vertices    = vertex_buffer,
		indices     = index_buffer,
		index_count = u32(len(indices)),
		topology    = topology,
		skin        = -1,
		material    = MATERIAL_DEFAULTS,
	}, nil
}

// A model of one part, from one lump of geometry. Bounds are measured off the
// vertices on the way past, since they are right here and will not be later.
create_model_from_mesh :: proc(vertices: []Vertex3D, indices: []u32, topology := Mesh_Topology.TRIANGLES) -> (Model, Error) {
	part, err := upload_mesh(vertices, indices, topology)
	if err != nil do return {}, err

	parts := make([]Model_Part, 1)
	parts[0] = part

	low  := vertices[0].pos
	high := vertices[0].pos
	for v in vertices[1:] {
		low  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
		high = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
	}

	return Model{parts = parts, bounds_min = low, bounds_max = high}, nil
}

/*
	Gives a model's buffers, textures, skeleton and clips back.

	A texture shared between parts -- which is every model built round one atlas
	-- is released once rather than once per part that points at it.
*/
destroy_model :: proc(model: ^Model) {
	// Freed before the early return below, because a skeleton is plain memory
	// and does not care whether there is still a GPU to give buffers back to.
	destroy_skeleton(&model.skeleton)
	destroy_animations(model.animations)
	model.animations = nil

	device := mbi.renderer.device
	if device == nil do return

	/*
		The loader uploads each glTF image once and hands the same texture to
		every material field that points at it -- a model built round a
		single atlas has all of its parts sharing one, and
		`read_material`/`resolve_texture` (model_load.odin) additionally
		share one GPU texture between, say, `metal_rough` and `occlusion`
		when a file packs both into the same image (the "ORM" convention --
		see `read_material`'s own comment). Releasing per field would then
		give the same texture back as many times as there are references to
		it, so each is only released the first time it is seen, keyed by the
		pointer rather than by which field held it.
	*/
	released := make(map[^sdl.GPUTexture]bool, len(model.parts), context.temp_allocator)
	defer delete(released)

	release_once :: proc(device: ^sdl.GPUDevice, released: ^map[^sdl.GPUTexture]bool, texture: ^sdl.GPUTexture) {
		if texture == nil do return
		if _, seen := released[texture]; seen do return
		sdl.ReleaseGPUTexture(device, texture)
		released[texture] = true
	}

	for &part in model.parts {
		delete(part.joint_map)
		if part.vertices != nil do sdl.ReleaseGPUBuffer(device, part.vertices)
		if part.indices  != nil do sdl.ReleaseGPUBuffer(device, part.indices)

		release_once(device, &released, part.material.textures.base)
		release_once(device, &released, part.material.textures.metal_rough)
		release_once(device, &released, part.material.textures.occlusion)
		release_once(device, &released, part.material.textures.emissive)
		// .normal is never filled in by this loader -- see Material_Textures'
		// own doc comment -- so there is nothing there to release.

		part.vertices = nil
		part.indices  = nil
		part.material.textures = {}
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
create_cube_model :: proc(size: f32 = 1) -> (Model, Error) {
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

	return create_model_from_mesh(vertices, indices)
}

/*
	A flat square of `size` units on the ground plane, facing up.

	The same four corners as the cube's top face, wound the same way, so a plane
	and the top of a cube agree about which side is out.
*/
create_plane_model :: proc(size: f32 = 1) -> (Model, Error) {
	h := size * 0.5

	vertices := []Vertex3D{
		{pos = {-h, 0,  h}, normal = {0, 1, 0}, uv = {0, 1}},
		{pos = { h, 0,  h}, normal = {0, 1, 0}, uv = {1, 1}},
		{pos = { h, 0, -h}, normal = {0, 1, 0}, uv = {1, 0}},
		{pos = {-h, 0, -h}, normal = {0, 1, 0}, uv = {0, 0}},
	}

	indices := []u32{0, 1, 2, 0, 2, 3}

	return create_model_from_mesh(vertices, indices)
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
create_sphere_model :: proc(radius: f32 = 1, rings: int = 16, sectors: int = 24) -> (Model, Error) {
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

	return create_model_from_mesh(vertices, indices[:])
}

/*
	A cylinder of `radius` and `height`, upright about Y and centred on its own
	origin, the way `create_cube_model` and `create_sphere_model` are.

	**The side and the two caps share no vertices.** A cap's normal points along
	Y and the side's points outwards, so a shared rim vertex would have to
	average the two and round the edge off -- the same reason the cube is
	twenty-four vertices rather than eight.

	The side runs to `<=` sectors so the seam where the texture wraps has two
	vertices in the same place with different uvs, as the sphere's does. The
	caps do not: they have no seam, and a fan round a middle vertex is the
	fewest triangles that closes them.

	Wound counter-clockwise seen from outside, which is what the pipeline's
	`front_face` expects. **Checked** rather than reasoned: every one of the 96
	triangles at the default sector count has its cross product pointing away
	from the axis, every edge is used exactly twice, and the signed volume comes
	to 0.7765 against a 24-sided prism's exact 0.78540 * cos-correction --
	0.98862 of the ideal cylinder, which is what `12 * sin(15 degrees) / pi`
	says a 24-gon should be. The first cut had the side wall inside out and
	looked right in the source.
*/
create_cylinder_model :: proc(radius: f32 = 0.5, height: f32 = 1, sectors: int = 24) -> (Model, Error) {
	sectors := max(sectors, 3)
	h := height * 0.5

	// The side: two rings of sectors+1. Each cap: a middle vertex and a ring of
	// sectors round it.
	side_count := (sectors + 1) * 2
	cap_count  := (sectors + 1) * 2

	vertices := make([]Vertex3D, side_count + cap_count, context.temp_allocator)
	indices  := make([dynamic]u32, 0, sectors * 6 + sectors * 6, context.temp_allocator)

	for s in 0 ..= sectors {
		theta := 2 * math.PI * f32(s) / f32(sectors)
		out   := [3]f32{math.cos(theta), 0, math.sin(theta)}
		u     := f32(s) / f32(sectors)

		vertices[s]               = Vertex3D{pos = {out.x * radius,  h, out.z * radius}, normal = out, uv = {u, 0}}
		vertices[sectors + 1 + s] = Vertex3D{pos = {out.x * radius, -h, out.z * radius}, normal = out, uv = {u, 1}}
	}

	for s in 0 ..< sectors {
		top    := u32(s)
		bottom := u32(sectors + 1 + s)
		append(&indices, top, bottom + 1, bottom)
		append(&indices, top, top + 1, bottom + 1)
	}

	// Each cap is its own middle vertex followed by its own ring, so the two
	// fans below can index them by an offset and a sector alone.
	top_middle    := side_count
	bottom_middle := side_count + sectors + 1

	vertices[top_middle]    = Vertex3D{pos = {0,  h, 0}, normal = { 0,  1, 0}, uv = {0.5, 0.5}}
	vertices[bottom_middle] = Vertex3D{pos = {0, -h, 0}, normal = { 0, -1, 0}, uv = {0.5, 0.5}}

	for s in 0 ..< sectors {
		theta := 2 * math.PI * f32(s) / f32(sectors)
		x, z  := math.cos(theta), math.sin(theta)

		vertices[top_middle + 1 + s]    = Vertex3D{pos = {x * radius,  h, z * radius}, normal = { 0,  1, 0}, uv = {x * 0.5 + 0.5, z * 0.5 + 0.5}}
		vertices[bottom_middle + 1 + s] = Vertex3D{pos = {x * radius, -h, z * radius}, normal = { 0, -1, 0}, uv = {x * 0.5 + 0.5, z * 0.5 + 0.5}}
	}

	for s in 0 ..< sectors {
		next := (s + 1) % sectors

		// Seen from above, the top's ring runs clockwise in x/z, so the fan is
		// wound middle, next, s to come out counter-clockwise from outside; the
		// bottom, seen from below, is the other way round.
		append(&indices, u32(top_middle), u32(top_middle + 1 + next), u32(top_middle + 1 + s))
		append(&indices, u32(bottom_middle), u32(bottom_middle + 1 + s), u32(bottom_middle + 1 + next))
	}

	return create_model_from_mesh(vertices, indices[:])
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
create_cube_wires_model :: proc(size: f32 = 1) -> (Model, Error) {
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

	return create_model_from_mesh(vertices, indices, .LINES)
}

/*
	A grid of lines on the ground plane, centred on the origin.

	`slices` squares across and the same again deep, each `spacing` units on a
	side. `draw_grid` keeps one of these and rebuilds it only when the numbers
	change, so a game asking for the same grid every frame builds it once.
*/
create_grid_model :: proc(slices: int = 10, spacing: f32 = 1) -> (Model, Error) {
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

	return create_model_from_mesh(vertices, indices, .LINES)
}
