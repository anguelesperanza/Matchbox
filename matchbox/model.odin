
package matchbox

/*
	Model -- loading
	----------------
	Reading a `.gltf` or `.glb` off disk and putting it on the GPU.

	The parsing is `matchbox/gltf2`'s, which is a vendored package and not
	something to reimplement: it reads the JSON, unpacks the GLB chunks, and
	decodes the base64 `data:` URIs that a self-contained export keeps its
	buffers and textures in. What is here is everything after that -- pulling
	vertices out of accessors, flattening the node hierarchy, and handing the
	results to the GPU.

	**Why the accessors are read here rather than with `gltf2.buffer_slice`.**
	That helper asserts when a buffer view declares a `byteStride`, and every
	file this was written against declares one -- Blockbench writes a stride of
	12 on a tightly packed vec3 buffer, which is redundant but perfectly legal.
	So the helper cannot read the models it would be used for. Reading the bytes
	directly is forty lines, handles interleaved data as a side effect, and
	leaves the vendored package untouched.

	**What is read, and what is ignored.** Positions, normals, texture
	coordinates, indices, and a material's base colour texture and factor. Not
	skins, animations, cameras, morph targets, or any of the PBR channels past
	base colour -- see D8. A file may contain them; they are skipped rather than
	failed on.
*/

import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"

import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

import gltf "./gltf2"

// -----------------------------------------------------------------------
// Loading
// -----------------------------------------------------------------------

/*
	Loads a model from a `.gltf` or `.glb` file.

	Through `read_entire_file`, so a model shipped inside an Android apk is
	reachable -- `gltf2.load_from_file` would reach for `core:os` and find
	nothing there.

	The scene's node hierarchy is flattened: every node's transform is
	accumulated down the tree and baked into the vertices, so the Model that
	comes back is in the file's own space and needs no further arrangement.
	Without that a model built out of parts -- a stove with its doors as
	separate nodes -- arrives as a heap at the origin.

	Returns `ok = false` and logs on a file that cannot be read or parsed. A
	missing model is a shipping mistake rather than a crash.
*/
load_model :: proc(path: string) -> (model: Model, ok: bool) {
	bytes, read := read_entire_file(path, context.allocator)
	if !read {
		log.errorf("could not read model %s", path)
		return {}, false
	}
	defer delete(bytes)

	// GLB copies its binary chunks out of `bytes` during parse, so freeing them
	// above is safe for both forms.
	is_glb := strings.equal_fold(filepath.ext(path), ".glb")

	// Only used for a model that keeps its buffers or textures in files beside
	// it, which none of the assets this was built for do -- they embed
	// everything.
	//
	// Borrowed, not owned: `filepath.dir` hands back a slice of the string it
	// was given rather than a new one, so deleting it frees a pointer into the
	// middle of somebody else's allocation. Doing that crashes with heap
	// corruption several function calls later, in a place with nothing to do
	// with paths.
	dir := filepath.dir(path)

	data, err := gltf.parse(bytes, {is_glb = is_glb, gltf_dir = dir})
	if err != nil {
		log.errorf("could not parse model %s: %v", path, err)
		return {}, false
	}
	defer gltf.unload(data)

	return model_from_gltf(data), true
}

// Everything after the parse: walk the scene, build the parts, measure the
// bounds.
@(private)
model_from_gltf :: proc(data: ^gltf.Data) -> Model {
	parts := make([dynamic]Model_Part)

	// Textures are shared between parts -- the stove's nine meshes use two
	// between them -- so each glTF texture is uploaded once and handed out.
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture, context.temp_allocator)
	defer delete(uploaded)

	low  := [3]f32{ max(f32),  max(f32),  max(f32)}
	high := [3]f32{-max(f32), -max(f32), -max(f32)}

	// The default scene, or the first one, or -- for a file with no scene at
	// all, which is legal -- every mesh at the origin.
	scene_index := data.scene.? or_else 0

	if len(data.scenes) > 0 && int(scene_index) < len(data.scenes) {
		for root in data.scenes[scene_index].nodes {
			gather_node(data, root, linalg.MATRIX4F32_IDENTITY, &parts, &uploaded, &low, &high)
		}
	} else {
		for _, mesh_index in data.meshes {
			gather_mesh(data, gltf.Integer(mesh_index), linalg.MATRIX4F32_IDENTITY, &parts, &uploaded, &low, &high)
		}
	}

	if len(parts) == 0 {
		log.error("model has no drawable primitives")
		return {}
	}

	return Model{parts = parts[:], bounds_min = low, bounds_max = high}
}

/*
	Walks one node and everything under it.

	`parent` is the transform accumulated so far. glTF nodes carry either a
	matrix or a translation/rotation/scale triple, never both -- and the parser
	defaults the one that is absent to the identity, so multiplying them
	together is right either way and needs no test for which form was used.
*/
@(private)
gather_node :: proc(
	data:     ^gltf.Data,
	index:    gltf.Integer,
	parent:   matrix[4, 4]f32,
	parts:    ^[dynamic]Model_Part,
	uploaded: ^map[gltf.Integer]^sdl.GPUTexture,
	low, high: ^[3]f32,
) {
	if int(index) >= len(data.nodes) do return
	node := data.nodes[index]

	world := parent * node.mat * transform_matrix(Transform{
		position = node.translation,
		rotation = node.rotation,
		scale    = node.scale,
	})

	if mesh, has_mesh := node.mesh.?; has_mesh {
		gather_mesh(data, mesh, world, parts, uploaded, low, high)
	}

	for child in node.children {
		gather_node(data, child, world, parts, uploaded, low, high)
	}
}

// One mesh's primitives, each becoming a part.
@(private)
gather_mesh :: proc(
	data:     ^gltf.Data,
	index:    gltf.Integer,
	world:    matrix[4, 4]f32,
	parts:    ^[dynamic]Model_Part,
	uploaded: ^map[gltf.Integer]^sdl.GPUTexture,
	low, high: ^[3]f32,
) {
	if int(index) >= len(data.meshes) do return

	// Normals are directions, not places: they must not pick up the
	// translation, and under an uneven scale they shear unless the inverse
	// transpose is used. Worked out once per mesh rather than per vertex.
	normal_matrix := linalg.matrix4_inverse_transpose_f32(world)

	for primitive in data.meshes[index].primitives {
		// Triangles only. A file may hold line or point primitives and they are
		// skipped rather than drawn wrongly.
		if primitive.mode != .Triangles do continue

		part, vertices, made := primitive_part(data, primitive, world, normal_matrix, uploaded)
		if !made do continue

		for v in vertices {
			low^  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
			high^ = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
		}

		append(parts, part)
	}
}

/*
	One primitive: vertices baked into model space, indices, and a material.

	The returned vertex slice is temp-allocated and only good for measuring the
	bounds -- the copy that matters is already on the GPU by then.
*/
@(private)
primitive_part :: proc(
	data:          ^gltf.Data,
	primitive:     gltf.Mesh_Primitive,
	world:         matrix[4, 4]f32,
	normal_matrix: matrix[4, 4]f32,
	uploaded:      ^map[gltf.Integer]^sdl.GPUTexture,
) -> (part: Model_Part, vertices: []Vertex3D, ok: bool) {
	position_accessor, has_position := primitive.attributes["POSITION"]
	if !has_position {
		log.error("primitive has no POSITION, skipped")
		return {}, nil, false
	}

	positions := read_vec3(data, position_accessor) or_return
	count     := len(positions)

	normals := read_vec3_optional(data, primitive.attributes, "NORMAL", count)
	uvs     := read_vec2_optional(data, primitive.attributes, "TEXCOORD_0", count)

	vertices = make([]Vertex3D, count, context.temp_allocator)
	for i in 0 ..< count {
		// Baked here rather than at draw time. A node transform is a property
		// of the file's arrangement, not of where the game later puts the
		// model, so folding it in now means a part is one buffer and one draw.
		p := world * [4]f32{positions[i].x, positions[i].y, positions[i].z, 1}
		n := normal_matrix * [4]f32{normals[i].x, normals[i].y, normals[i].z, 0}

		vertices[i] = Vertex3D{
			pos    = p.xyz,
			normal = linalg.normalize0(n.xyz),
			uv     = uvs[i],
		}
	}

	indices := read_indices(data, primitive, count)

	part = upload_mesh(vertices, indices)
	part.texture, part.sampler = material_texture(data, primitive.material, uploaded)

	return part, vertices, true
}

// -----------------------------------------------------------------------
// Materials
// -----------------------------------------------------------------------

/*
	The base colour texture of a primitive's material, uploaded once and shared.

	Everything else a glTF material can carry -- metallic, roughness, normal
	maps, occlusion, emissive -- is ignored (D8). A primitive with no material,
	or a material with no base colour texture, comes back nil and is drawn flat
	in its tint.

	The sampler is the nearest-neighbour one sprites use, which is not a
	shortcut: every model this was written against declares `magFilter` 9728,
	which is NEAREST, because they are pixel-art textures and smoothing them
	would be undoing the art.
*/
@(private)
material_texture :: proc(
	data:     ^gltf.Data,
	material: Maybe(gltf.Integer),
	uploaded: ^map[gltf.Integer]^sdl.GPUTexture,
) -> (^sdl.GPUTexture, ^sdl.GPUSampler) {
	material_index := material.? or_else max(gltf.Integer)
	if int(material_index) >= len(data.materials) do return nil, nil

	pbr := data.materials[material_index].metallic_roughness.? or_else gltf.Material_Metallic_Roughness{}
	info, has_texture := pbr.base_color_texture.?
	if !has_texture do return nil, nil

	if int(info.index) >= len(data.textures) do return nil, nil
	source, has_source := data.textures[info.index].source.?
	if !has_source do return nil, nil

	if existing, found := uploaded[source]; found {
		return existing, mbi.renderer.sprite_sampler
	}

	if int(source) >= len(data.images) do return nil, nil

	// Embedded rather than a file beside the model, in every asset this was
	// built for -- the parser has already turned the base64 into bytes. An
	// image the parser could not resolve is still a string here.
	encoded, is_bytes := data.images[source].uri.([]byte)
	if !is_bytes {
		// A .glb keeps its images in the binary chunk instead: a buffer view
		// and a mime type, with no `uri` at all. That is the ordinary way a
		// GLB carries a texture rather than an edge case, so slice the bytes
		// out of the buffer the parser already copied.
		encoded, is_bytes = image_view_bytes(data, source)
	}
	if !is_bytes {
		log.error("model texture is not embedded, skipped")
		return nil, nil
	}

	texture := decode_and_upload(encoded)
	if texture == nil do return nil, nil

	uploaded[source] = texture
	return texture, mbi.renderer.sprite_sampler
}

/*
	An image's bytes out of the binary chunk.

	`uri` and `buffer_view` are the two ways glTF carries an image, and they are
	mutually exclusive: a `.gltf` writes a path or a base64 data URI, a `.glb`
	writes a view into the buffer chunk. Only the first was read here, so every
	GLB loaded as untextured geometry -- the mesh was fine, the material just
	never found its image.
*/
@(private)
image_view_bytes :: proc(data: ^gltf.Data, source: gltf.Integer) -> (bytes: []byte, ok: bool) {
	view_index := data.images[source].buffer_view.? or_return
	if int(view_index) >= len(data.buffer_views) do return nil, false
	view := data.buffer_views[view_index]

	if int(view.buffer) >= len(data.buffers) do return nil, false
	buffer := data.buffers[view.buffer].uri.([]byte) or_return

	start := int(view.byte_offset)
	end   := start + int(view.byte_length)
	if end > len(buffer) do return nil, false

	return buffer[start:end], true
}

// PNG or JPEG bytes to a GPU texture, through the same stb_image and the same
// staging path a sprite uses.
@(private)
decode_and_upload :: proc(encoded: []byte) -> ^sdl.GPUTexture {
	width, height, channels: i32

	pixels := stbi.load_from_memory(raw_data(encoded), i32(len(encoded)), &width, &height, &channels, 4)
	if pixels == nil {
		log.errorf("could not decode a model texture: %s", stbi.failure_reason())
		return nil
	}
	defer stbi.image_free(pixels)

	return upload_texture(pixels, width, height)
}

// -----------------------------------------------------------------------
// Accessors
// -----------------------------------------------------------------------

/*
	Where one accessor's elements start, how far apart they are, and how many.

	A buffer view may declare a `byteStride`, and when it does that is the step
	between elements rather than the element's own size -- which is how
	interleaved vertex data is described, and also what Blockbench writes on
	tightly packed data where the two happen to be equal. Either way the stride
	is what to walk by; the element size is only the fallback when none is given.
*/
@(private)
accessor_span :: proc(data: ^gltf.Data, index: gltf.Integer) -> (bytes: []byte, stride, count: int, ok: bool) {
	if int(index) >= len(data.accessors) do return nil, 0, 0, false
	accessor := data.accessors[index]

	if _, sparse := accessor.sparse.?; sparse {
		log.error("sparse accessors are not supported, primitive skipped")
		return nil, 0, 0, false
	}

	view_index := accessor.buffer_view.? or_return
	if int(view_index) >= len(data.buffer_views) do return nil, 0, 0, false
	view := data.buffer_views[view_index]

	if int(view.buffer) >= len(data.buffers) do return nil, 0, 0, false
	buffer, is_bytes := data.buffers[view.buffer].uri.([]byte)
	if !is_bytes {
		log.error("model buffer was not resolved to bytes, primitive skipped")
		return nil, 0, 0, false
	}

	element := component_size(accessor.component_type) * component_count(accessor.type)
	stride   = int(view.byte_stride.? or_else gltf.Integer(element))
	count    = int(accessor.count)

	start := int(accessor.byte_offset) + int(view.byte_offset)
	if start + (count - 1) * stride + element > len(buffer) {
		log.error("accessor runs past the end of its buffer, primitive skipped")
		return nil, 0, 0, false
	}

	return buffer[start:], stride, count, true
}

@(private)
component_size :: proc(type: gltf.Component_Type) -> int {
	switch type {
	case .Byte, .Unsigned_Byte:   return 1
	case .Short, .Unsigned_Short: return 2
	case .Unsigned_Int, .Float:   return 4
	}
	return 0
}

@(private)
component_count :: proc(type: gltf.Accessor_Type) -> int {
	switch type {
	case .Scalar:  return 1
	case .Vector2: return 2
	case .Vector3: return 3
	case .Vector4: return 4
	case .Matrix2: return 4
	case .Matrix3: return 9
	case .Matrix4: return 16
	}
	return 0
}

// Positions and normals, which glTF requires to be floats.
@(private)
read_vec3 :: proc(data: ^gltf.Data, index: gltf.Integer) -> (out: [][3]f32, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float positions or normals, primitive skipped")
		return nil, false
	}

	out = make([][3]f32, count, context.temp_allocator)
	for i in 0 ..< count {
		out[i] = (cast(^[3]f32)&bytes[i * stride])^
	}

	return out, true
}

// A NORMAL that is not there. Legal, and it means flat shading off the
// triangle -- but there is nowhere to put a per-face normal in a vertex, so
// this fills in an up vector and lets the fixed light give a readable result.
// None of the files this was written for take this path.
@(private)
read_vec3_optional :: proc(
	data: ^gltf.Data, attributes: map[string]gltf.Integer, name: string, count: int,
) -> [][3]f32 {
	if index, present := attributes[name]; present {
		if values, ok := read_vec3(data, index); ok && len(values) >= count {
			return values
		}
	}

	log.infof("model primitive has no %s, substituting", name)

	out := make([][3]f32, count, context.temp_allocator)
	for i in 0 ..< count do out[i] = {0, 1, 0}
	return out
}

/*
	Texture coordinates, which may be floats or normalised integers.

	glTF allows a uv to be stored as unsigned bytes or shorts to save space, in
	which case the value runs over the whole range of the type and is divided
	down. Rare in an exported model and cheap to support.
*/
@(private)
read_vec2_optional :: proc(
	data: ^gltf.Data, attributes: map[string]gltf.Integer, name: string, count: int,
) -> [][2]f32 {
	out := make([][2]f32, count, context.temp_allocator)

	index, present := attributes[name]
	if !present do return out // all zeroes: untextured, and the tint carries it

	bytes, stride, available, ok := accessor_span(data, index)
	if !ok do return out

	type := data.accessors[index].component_type

	for i in 0 ..< min(count, available) {
		at := &bytes[i * stride]

		switch type {
		case .Float:
			out[i] = (cast(^[2]f32)at)^
		case .Unsigned_Byte:
			raw := (cast(^[2]u8)at)^
			out[i] = {f32(raw[0]) / 255, f32(raw[1]) / 255}
		case .Unsigned_Short:
			raw := (cast(^[2]u16)at)^
			out[i] = {f32(raw[0]) / 65535, f32(raw[1]) / 65535}
		case .Byte, .Short, .Unsigned_Int:
			fallthrough
		case:
			log.error("unsupported texture coordinate type")
			return out
		}
	}

	return out
}

/*
	A primitive's indices, widened to u32.

	glTF stores them as bytes, shorts or ints depending on how many vertices
	there are, and the GPU buffer is always 32-bit -- one index format for the
	whole renderer is worth more than the two bytes a short would save.

	A primitive with no indices at all is legal and means the vertices are
	already in order, so this makes the sequence it implies.
*/
@(private)
read_indices :: proc(data: ^gltf.Data, primitive: gltf.Mesh_Primitive, vertex_count: int) -> []u32 {
	index, present := primitive.indices.?

	if !present {
		out := make([]u32, vertex_count, context.temp_allocator)
		for i in 0 ..< vertex_count do out[i] = u32(i)
		return out
	}

	bytes, stride, count, ok := accessor_span(data, index)
	if !ok do return nil

	out := make([]u32, count, context.temp_allocator)
	type := data.accessors[index].component_type

	for i in 0 ..< count {
		at := &bytes[i * stride]

		switch type {
		case .Unsigned_Byte:  out[i] = u32((cast(^u8)at)^)
		case .Unsigned_Short: out[i] = u32((cast(^u16)at)^)
		case .Unsigned_Int:   out[i] = (cast(^u32)at)^
		case .Byte, .Short, .Float:
			fallthrough
		case:
			log.error("unsupported index type")
			return nil
		}
	}

	return out
}

// package matchbox

// /*
// 	Model
// 	-----
// 	Geometry that lives on the GPU, and the first thing in Matchbox to own a
// 	vertex buffer of its own. Everything in 2D draws the one shared quad; a
// 	model is the case that could not.

// 	The name is `Model` and not `Mesh` because `Mesh` is already the texture
// 	holder that `Sprite` embeds -- see D6 in 3d.md. A Model is what one file
// 	loads into: several parts, each with its own geometry and its own material,
// 	because a glTF scene routinely has more than one of both.

// 	Stage 1 generates models in code and every part is untextured. Stage 4 adds
// 	the loader, which is why the part already has room for a texture nothing
// 	fills in yet.
// */

// import "core:math"

// import sdl "vendor:sdl3"

// /*
// 	Whether a part's indices describe filled triangles or bare lines.

// 	The zero value is triangles, so everything written before wireframes existed
// 	still means what it did. A part carries this rather than a Model, because
// 	a loaded file could reasonably hold both -- and because it is the pipeline
// 	selector, and pipelines are chosen per draw.
// */
// Mesh_Topology :: enum {
// 	TRIANGLES,
// 	LINES,
// }

// /*
// 	One buffer of geometry with one material.

// 	`index_count` rather than a slice: the vertices are on the GPU by the time
// 	this exists and the CPU copy is gone, so the count is the only thing left
// 	that says how much to draw.
// */
// Model_Part :: struct {
// 	vertices:    ^sdl.GPUBuffer,
// 	indices:     ^sdl.GPUBuffer,
// 	index_count: u32,
// 	topology:    Mesh_Topology,

// 	// Filled in by the loader in stage 4. A part with no texture is drawn by
// 	// the flat pipeline in its tint alone.
// 	texture:     ^sdl.GPUTexture,
// 	sampler:     ^sdl.GPUSampler,
// }

// /*
// 	A whole model, as one file or one generator produced it.

// 	`bounds_min` / `bounds_max` are the model's own extents in its own space,
// 	worked out once while the vertex data is in hand. It is not a collision
// 	feature -- Matchbox has none, see D7 -- it is what a game measures a
// 	`b3.MakeBoxHull` from, and what `draw_box_wires` is pointed at to see the
// 	thing it just loaded.
// */
// Model :: struct {
// 	parts:      []Model_Part,
// 	bounds_min: [3]f32,
// 	bounds_max: [3]f32,
// }

// // The middle of the model's own bounds, and how big it is. What a game hands to
// // a physics library, which wants a centre and half-extents rather than corners.
// model_center :: proc(model: Model) -> [3]f32 {
// 	return (model.bounds_min + model.bounds_max) * 0.5
// }

// model_size :: proc(model: Model) -> [3]f32 {
// 	return model.bounds_max - model.bounds_min
// }

// /*
// 	Puts one lump of geometry on the GPU.

// 	Both buffers go through the same staging path everything else uses, so a
// 	part costs two copy passes at load and nothing afterwards. The slices belong
// 	to the caller and are not kept.
// */
// upload_mesh :: proc(vertices: []Vertex3D, indices: []u32, topology := Mesh_Topology.TRIANGLES) -> Model_Part {
// 	ensure(len(vertices) > 0, "a mesh needs vertices")
// 	ensure(len(indices) > 0, "a mesh needs indices")

// 	return Model_Part{
// 		vertices    = upload_buffer(raw_data(vertices), u32(len(vertices) * size_of(Vertex3D)), {.VERTEX}),
// 		indices     = upload_buffer(raw_data(indices),  u32(len(indices)  * size_of(u32)),      {.INDEX}),
// 		index_count = u32(len(indices)),
// 		topology    = topology,
// 	}
// }

// // A model of one part, from one lump of geometry. Bounds are measured off the
// // vertices on the way past, since they are right here and will not be later.
// model_from_mesh :: proc(vertices: []Vertex3D, indices: []u32, topology := Mesh_Topology.TRIANGLES) -> Model {
// 	parts := make([]Model_Part, 1)
// 	parts[0] = upload_mesh(vertices, indices, topology)

// 	low  := vertices[0].pos
// 	high := vertices[0].pos
// 	for v in vertices[1:] {
// 		low  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
// 		high = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
// 	}

// 	return Model{parts = parts, bounds_min = low, bounds_max = high}
// }

// destroy_model :: proc(model: ^Model) {
// 	device := mbi.renderer.device
// 	if device == nil do return

// 	for &part in model.parts {
// 		if part.vertices != nil do sdl.ReleaseGPUBuffer(device, part.vertices)
// 		if part.indices  != nil do sdl.ReleaseGPUBuffer(device, part.indices)

// 		// The texture is the part's own once stage 4's loader makes one. A
// 		// texture shared with something else does not belong here, which is why
// 		// the loader will be the only thing that sets it.
// 		if part.texture != nil do sdl.ReleaseGPUTexture(device, part.texture)

// 		part.vertices = nil
// 		part.indices  = nil
// 		part.texture  = nil
// 	}

// 	delete(model.parts)
// 	model.parts = nil
// }

// // -----------------------------------------------------------------------
// // Generated geometry
// // -----------------------------------------------------------------------

// /*
// 	A cube of `size` units, centred on its own origin.

// 	Twenty-four vertices for six faces rather than eight shared corners: a
// 	shared corner would have to average the normals of the three faces meeting
// 	there, which rounds the edges off a shape whose whole character is that they
// 	are sharp.

// 	Wound counter-clockwise seen from outside, which is what the pipeline's
// 	`front_face` expects and what glTF produces.
// */
// cube_model :: proc(size: f32 = 1) -> Model {
// 	h := size * 0.5

// 	// Per face: the four corners in counter-clockwise order seen from outside,
// 	// and the direction the face points.
// 	Face :: struct {
// 		corners: [4][3]f32,
// 		normal:  [3]f32,
// 	}

// 	faces := [6]Face{
// 		{{{-h, -h,  h}, { h, -h,  h}, { h,  h,  h}, {-h,  h,  h}}, { 0,  0,  1}}, // front
// 		{{{ h, -h, -h}, {-h, -h, -h}, {-h,  h, -h}, { h,  h, -h}}, { 0,  0, -1}}, // back
// 		{{{ h, -h,  h}, { h, -h, -h}, { h,  h, -h}, { h,  h,  h}}, { 1,  0,  0}}, // right
// 		{{{-h, -h, -h}, {-h, -h,  h}, {-h,  h,  h}, {-h,  h, -h}}, {-1,  0,  0}}, // left
// 		{{{-h,  h,  h}, { h,  h,  h}, { h,  h, -h}, {-h,  h, -h}}, { 0,  1,  0}}, // top
// 		{{{-h, -h, -h}, { h, -h, -h}, { h, -h,  h}, {-h, -h,  h}}, { 0, -1,  0}}, // bottom
// 	}

// 	uvs := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// 	vertices := make([]Vertex3D, 24, context.temp_allocator)
// 	indices  := make([]u32,      36, context.temp_allocator)

// 	for face, f in faces {
// 		base := u32(f) * 4

// 		for corner, c in face.corners {
// 			vertices[int(base) + c] = Vertex3D{
// 				pos    = corner,
// 				normal = face.normal,
// 				uv     = uvs[c],
// 			}
// 		}

// 		i := f * 6
// 		indices[i + 0] = base + 0
// 		indices[i + 1] = base + 1
// 		indices[i + 2] = base + 2
// 		indices[i + 3] = base + 0
// 		indices[i + 4] = base + 2
// 		indices[i + 5] = base + 3
// 	}

// 	return model_from_mesh(vertices, indices)
// }

// /*
// 	A flat square of `size` units on the ground plane, facing up.

// 	The same four corners as the cube's top face, wound the same way, so a plane
// 	and the top of a cube agree about which side is out.
// */
// plane_model :: proc(size: f32 = 1) -> Model {
// 	h := size * 0.5

// 	vertices := []Vertex3D{
// 		{pos = {-h, 0,  h}, normal = {0, 1, 0}, uv = {0, 1}},
// 		{pos = { h, 0,  h}, normal = {0, 1, 0}, uv = {1, 1}},
// 		{pos = { h, 0, -h}, normal = {0, 1, 0}, uv = {1, 0}},
// 		{pos = {-h, 0, -h}, normal = {0, 1, 0}, uv = {0, 0}},
// 	}

// 	indices := []u32{0, 1, 2, 0, 2, 3}

// 	return model_from_mesh(vertices, indices)
// }

// /*
// 	A sphere of `radius`, built the usual way out of rings of latitude and
// 	sectors of longitude.

// 	The defaults are a shape smooth enough to read as round and cheap enough to
// 	scatter a hundred of. A normal here is just the direction from the centre,
// 	which is the one case where the normal falls out of the position for free.

// 	Both loops run to `<=` their count, so the seam where longitude wraps has
// 	two vertices at the same place with different uvs -- otherwise the last
// 	sector would stretch the whole texture backwards across itself.
// */
// sphere_model :: proc(radius: f32 = 1, rings: int = 16, sectors: int = 24) -> Model {
// 	rings   := max(rings, 2)
// 	sectors := max(sectors, 3)

// 	vertices := make([]Vertex3D, (rings + 1) * (sectors + 1), context.temp_allocator)
// 	indices  := make([dynamic]u32, 0, rings * sectors * 6, context.temp_allocator)

// 	for r in 0 ..= rings {
// 		phi := math.PI * f32(r) / f32(rings) // 0 at the top, pi at the bottom
// 		y   := math.cos(phi)
// 		ring_radius := math.sin(phi)

// 		for s in 0 ..= sectors {
// 			theta := 2 * math.PI * f32(s) / f32(sectors)

// 			normal := [3]f32{ring_radius * math.cos(theta), y, ring_radius * math.sin(theta)}

// 			vertices[r * (sectors + 1) + s] = Vertex3D{
// 				pos    = normal * radius,
// 				normal = normal,
// 				uv     = {f32(s) / f32(sectors), f32(r) / f32(rings)},
// 			}
// 		}
// 	}

// 	for r in 0 ..< rings {
// 		for s in 0 ..< sectors {
// 			a := u32(r * (sectors + 1) + s)
// 			b := a + u32(sectors + 1)

// 			append(&indices, a, a + 1, b)
// 			append(&indices, a + 1, b + 1, b)
// 		}
// 	}

// 	return model_from_mesh(vertices, indices[:])
// }

// // -----------------------------------------------------------------------
// // Generated geometry -- lines
// // -----------------------------------------------------------------------

// /*
// 	The twelve edges of a cube, as lines.

// 	Eight vertices rather than the solid cube's twenty-four: an edge has no
// 	face, so there are no normals to disagree about and the corners can be
// 	shared. The normals are filled in anyway because the vertex layout is shared
// 	with the solid pipeline -- the line shader ignores them.
// */
// cube_wires_model :: proc(size: f32 = 1) -> Model {
// 	h := size * 0.5

// 	corners := [8][3]f32{
// 		{-h, -h, -h}, { h, -h, -h}, { h, -h,  h}, {-h, -h,  h}, // bottom, anticlockwise
// 		{-h,  h, -h}, { h,  h, -h}, { h,  h,  h}, {-h,  h,  h}, // top, the same way round
// 	}

// 	vertices := make([]Vertex3D, 8, context.temp_allocator)
// 	for corner, i in corners {
// 		vertices[i] = Vertex3D{pos = corner, normal = {0, 1, 0}, uv = {0, 0}}
// 	}

// 	indices := []u32{
// 		0, 1, 1, 2, 2, 3, 3, 0, // bottom
// 		4, 5, 5, 6, 6, 7, 7, 4, // top
// 		0, 4, 1, 5, 2, 6, 3, 7, // the uprights joining them
// 	}

// 	return model_from_mesh(vertices, indices, .LINES)
// }

// /*
// 	A grid of lines on the ground plane, centred on the origin.

// 	`slices` squares across and the same again deep, each `spacing` units on a
// 	side. `draw_grid` keeps one of these and rebuilds it only when the numbers
// 	change, so a game asking for the same grid every frame builds it once.
// */
// grid_model :: proc(slices: int = 10, spacing: f32 = 1) -> Model {
// 	slices := max(slices, 1)

// 	half  := f32(slices) * spacing * 0.5
// 	count := slices + 1

// 	vertices := make([]Vertex3D, count * 4, context.temp_allocator)
// 	indices  := make([]u32,      count * 4, context.temp_allocator)

// 	for i in 0 ..< count {
// 		offset := -half + f32(i) * spacing
// 		v      := i * 4

// 		// One line along z, one along x, so a single pass lays both directions.
// 		vertices[v + 0] = Vertex3D{pos = {offset, 0, -half}, normal = {0, 1, 0}}
// 		vertices[v + 1] = Vertex3D{pos = {offset, 0,  half}, normal = {0, 1, 0}}
// 		vertices[v + 2] = Vertex3D{pos = {-half,  0, offset}, normal = {0, 1, 0}}
// 		vertices[v + 3] = Vertex3D{pos = { half,  0, offset}, normal = {0, 1, 0}}

// 		indices[v + 0] = u32(v + 0)
// 		indices[v + 1] = u32(v + 1)
// 		indices[v + 2] = u32(v + 2)
// 		indices[v + 3] = u32(v + 3)
// 	}

// 	return model_from_mesh(vertices, indices, .LINES)
// }
