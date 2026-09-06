
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

/*
	TEMPORARY, see the block in skinned_primitive_part.

	  0  off, the real data
	  1  joints zeroed, real weights   -- isolates the weight attribute
	  2  real joints, weights {1,0,0,0} -- isolates the joint attribute
	  3  both, which is what proved one of them is at fault

	With a nil animator the palette is all identity, so `skin` should come out
	as the identity under every one of these. Whichever mode still shows the
	artifact names the attribute that is arriving wrong.
*/
SKIN_DIAG :: #config(SKIN_DIAG, 0)

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

	Returns a `File_Error` when the path could not be read and
	`Model_Error.Parse_Failed` when it could but the contents are not glTF. A
	missing model is a shipping mistake rather than a crash, and telling the two
	apart is the difference between "you forgot to copy the file" and "the
	export is wrong".
*/
load_model :: proc(path: string) -> (model: Model, err: Error) {
	bytes := read_entire_file(path, context.allocator) or_return
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

	data, parse_err := gltf.parse(bytes, {is_glb = is_glb, gltf_dir = dir})
	if parse_err != nil {
		log.errorf("could not parse model %s: %v", path, parse_err)
		return {}, Model_Error.Parse_Failed
	}
	defer gltf.unload(data)

	return model_from_gltf(data), nil
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
			gather_mesh(data, gltf.Integer(mesh_index), linalg.MATRIX4F32_IDENTITY, &parts, &uploaded, &low, &high, 0, nil)
		}
	}

	if len(parts) == 0 {
		log.error("model has no drawable primitives")
		return {}
	}

	return Model{
		parts      = parts[:],
		bounds_min = low,
		bounds_max = high,
		skeleton   = build_skeleton(data),
		animations = build_animations(data),
	}
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
		gather_mesh(data, mesh, world, parts, uploaded, low, high, index, node.skin)
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
	node:     gltf.Integer,
	skin:     Maybe(gltf.Integer),
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

		/*
			A skinned primitive takes the other path entirely. Its vertices
			belong to the skin's space and the joint matrices are what put them
			anywhere, so baking this node's transform into them -- which is what
			`primitive_part` exists to do -- would apply the arrangement twice.

			glTF says as much: the transform of a node with a skinned mesh is
			not applied to the mesh. `animator_resolve` divides it back out.
		*/
		skin_index, has_skin := skin.?
		if has_skin && "JOINTS_0" in primitive.attributes {
			part, vertices, made := skinned_primitive_part(
				data, primitive, int(skin_index), u32(node), uploaded)
			if !made do continue

			for v in vertices {
				low^  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
				high^ = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
			}

			append(parts, part)
			continue
		}

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

	err: Error
	part, err = upload_mesh(vertices, indices)
	if err != nil {
		log.errorf("could not upload a mesh primitive: %v", err)
		return {}, nil, false
	}

	part.texture, part.sampler = material_texture(data, primitive.material, uploaded)

	return part, vertices, true
}

/*
	One skinned primitive: the same three attributes, plus the joints and
	weights, and no node transform baked in.

	The bounds measured off these are the bind pose -- the shape the character
	was modelled in, arms out. That is the right answer for the thing bounds are
	for here, which is standing a model on the ground: a walk cycle moves the
	feet a few centimetres and a bounding box that breathed with the animation
	would make the model bob.
*/
@(private)
skinned_primitive_part :: proc(
	data:      ^gltf.Data,
	primitive: gltf.Mesh_Primitive,
	skin:      int,
	node:      u32,
	uploaded:  ^map[gltf.Integer]^sdl.GPUTexture,
) -> (part: Model_Part, vertices: []Vertex3D_Skinned, ok: bool) {
	position_accessor, has_position := primitive.attributes["POSITION"]
	if !has_position {
		log.error("skinned primitive has no POSITION, skipped")
		return {}, nil, false
	}

	positions := read_vec3(data, position_accessor) or_return
	count     := len(positions)

	normals := read_vec3_optional(data, primitive.attributes, "NORMAL", count)
	uvs     := read_vec2_optional(data, primitive.attributes, "TEXCOORD_0", count)
	joints  := read_joints(data, primitive.attributes, count)
	weights := read_weights(data, primitive.attributes, count)

	/*
		How many joints the palette this part will be drawn with actually holds.
		A vertex naming a joint past that reads off the end of a cbuffer array,
		which is not a crash and not a validation error -- it is whatever the
		last draw left there, so the character has one limb somewhere else
		entirely and nothing says why.

		Out of range is either a file whose skin and mesh disagree or a misread
		accessor on this side. Clamped to zero and reported once, because a
		vertex pinned to the root joint is a visible seam rather than a
		character stretched across the map.
	*/
	joint_limit := u32(MAX_JOINTS)
	if skin >= 0 && skin < len(data.skins) {
		joint_limit = u32(min(len(data.skins[skin].joints), MAX_JOINTS))
	}

	out_of_range := 0

	vertices = make([]Vertex3D_Skinned, count, context.temp_allocator)
	for i in 0 ..< count {
		joint  := joints[i]
		weight := weights[i]

		/*
			The weight goes with the joint index, and this used to keep it.

			Setting the index to 0 and leaving its weight alone does not drop
			the influence, which is what the message below claims -- it *moves*
			it, onto whatever joint 0 happens to be. On a character that is the
			root or the hips, so a vertex out at the ankle keeps a share of its
			say and is dragged toward the pelvis, taking its triangles with it
			as a spike. One vertex is enough to see.
		*/
		dropped := false
		for k in 0 ..< 4 {
			if joint[k] >= joint_limit {
				joint[k]  = 0
				weight[k] = 0
				dropped   = true
				out_of_range += 1
			}
		}

		/*
			Dropping a weight leaves the four summing short, and the skinning
			shader uses that sum unscaled -- so the vertex would land at `s`
			times its correct position, pulled toward the model's origin. The
			same trap `read_weights` renormalises against, reached from the
			other direction: that normalise runs before this, so this has to
			put the sum back itself.
		*/
		if dropped {
			sum := weight[0] + weight[1] + weight[2] + weight[3]
			if sum > 0 {
				weight = {weight[0] / sum, weight[1] / sum, weight[2] / sum, weight[3] / sum}
			} else {
				// Every influence this vertex had was out of range. Pinned to
				// the first joint, which is a visible seam rather than a
				// vertex on the origin dragging a triangle to the floor.
				joint  = {0, 0, 0, 0}
				weight = {1, 0, 0, 0}
			}
		}

		vertices[i] = Vertex3D_Skinned{
			pos     = positions[i],
			normal  = normals[i],
			uv      = uvs[i],
			joints  = joint,
			weights = weight,
		}

		/*
			TEMPORARY diagnostic -- delete with SKIN_DIAG above.

			Mode 3 (both) removed the artifact, so one of these two attributes
			is arriving wrong on Vulkan. Modes 1 and 2 say which: 1 keeps the
			real weights and 2 keeps the real joints, and the one that still
			shows it is the culprit.
		*/
		when SKIN_DIAG == 1 || SKIN_DIAG == 3 do vertices[i].joints  = {0, 0, 0, 0}
		when SKIN_DIAG == 2 || SKIN_DIAG == 3 do vertices[i].weights = {1, 0, 0, 0}
	}

	if out_of_range > 0 {
		log.errorf("skinned primitive names %v joint indices past the skin's %v joints; those weights were dropped",
			out_of_range, joint_limit)
	}

	indices := read_indices(data, primitive, count)

	err: Error
	part, err = upload_skinned_mesh(vertices, indices, skin, node)
	if err != nil {
		log.errorf("could not upload a skinned mesh primitive: %v", err)
		return {}, nil, false
	}

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

	// A texture that will not upload leaves the part untextured rather than
	// failing the load: the geometry is still worth having, and the caller
	// already treats a nil texture as "draw this flat".
	texture, err := upload_texture(pixels, width, height)
	if err != nil {
		log.errorf("could not upload a model texture: %v", err)
		return nil
	}

	return texture
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

/*
	Three floats per element, which is what glTF requires for positions,
	normals, translations and scales alike.

	The allocator is an argument because the two callers want different answers
	and nothing else about them differs. Vertex data is copied to the GPU
	immediately and never looked at again, so it takes the temp allocator;
	animation keyframes outlive the load and take a real one. This was two
	procedures that differed in that one word and in an error string.
*/
@(private)
read_vec3 :: proc(
	data: ^gltf.Data,
	index: gltf.Integer,
	allocator := context.temp_allocator,
) -> (out: [][3]f32, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float vec3 data, skipped")
		return nil, false
	}

	out = make([][3]f32, count, allocator)
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
