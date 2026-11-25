#+build windows

package matchbox

/*
	Model -- loading glTF (PC)
	==========================
	Reads a `.gltf` or `.glb` from the assets' `models/` folder and puts it on the GPU.

	Two halves:
	- `read_gltf_model` turns the file into `Model_Data`, plain CPU-side parts and encoded
	  images, with nothing on the GPU. It is public because the handhelds' build-time converter
	  reads glTF through it too, so the two can't disagree about what a file means.
	- `load_model` uploads that: one Mesh per part, one Texture per image.

	The parsing is the vendored `matchbox/gltf2`'s. What is here is everything after it,
	ported from main's model_load.odin without its GPU code, skinning, VRM and PBR materials:
	- The node hierarchy is flattened. Every node's transform is accumulated down the tree and
	  baked into its vertices, so the model is in the file's own space. Without that, a model
	  built from parts (a stove with its doors as separate nodes) arrives as a heap at the origin.
	- Accessors are read here rather than with the package's buffer helper, which asserts on a
	  `byteStride`, and Blockbench writes one even on tightly packed data. Reading by stride
	  also handles interleaved vertices.
	- Read: positions, normals, the first texture coordinates and vertex colours, indices, and a
	  material's base colour factor and texture, alpha mode and cutoff, and double-sidedness.
	  Skipped rather than failed on: skins and animations (G6), cameras, morph targets, line and
	  point primitives, and the other material channels.
*/

import "core:image"
import "core:image/jpeg"
import "core:image/png"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"

import gltf "./gltf2"

// The decoders register themselves with core:image when imported; nothing else names them
_ :: jpeg
_ :: png

/*
	A model from `filename` in the assets' `models/` folder (the target's own first, then the
	shared one, as for images). Stops with a message when the file is missing, isn't glTF, or
	has nothing to draw: a model that half-loaded would draw nothing with no sign why.
	`filter` is how its textures are sampled; .POINT suits the low-poly, pixel-textured models
	most handheld games use
*/
load_model :: proc(filename:string, filter:Filter_Mode = .POINT) -> (model:Model) {
	path := get_asset(filename, .MODEL)
	defer delete(path)

	data, ok := read_gltf_model(path)
	defer destroy_model_data(data)
	if ok == false {
		print("Could not read model", path)
		panic("Failed to load model")
	}

	textures := make([]Texture, len(data.images))
	for encoded, index in data.images {
		decoded, err := image.load_from_bytes(encoded, options = {.alpha_add_if_missing})
		if err != nil || decoded.depth != 8 || decoded.channels != 4 {
			// The geometry is still worth having: the part draws in its colour alone
			print("A texture in", path, "could not be decoded:", err)
			if decoded != nil do image.destroy(decoded)
			continue
		}
		textures[index] = create_texture_from_pixels(raw_data(decoded.pixels), i32(decoded.width), i32(decoded.height), filter)
		image.destroy(decoded)
	}
	return create_model_from_data(data, textures)
}

/*
	Reads a `.gltf` or `.glb` at `path` (a real path, not an asset name) into Model_Data. `ok` is
	false, with a printed reason, when the file can't be read, isn't glTF, or has nothing to
	draw. Free the result with destroy_model_data
*/
read_gltf_model :: proc(path:string) -> (data:Model_Data, ok:bool) {
	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		print("No such model file:", path)
		return
	}
	defer delete(bytes)

	// A .vrm is a GLB too; the extension says which container to unpack
	extension := filepath.ext(path)
	is_glb := strings.equal_fold(extension, ".glb") || strings.equal_fold(extension, ".vrm")

	// Borrowed, not owned: filepath.dir returns a slice of `path`, so it must not be deleted
	directory := filepath.dir(path)

	file, parse_error := gltf.parse(bytes, {is_glb = is_glb, gltf_dir = directory})
	if parse_error != nil {
		print("Not a glTF file:", path, parse_error)
		return
	}
	defer gltf.unload(file)

	data.bounds_min = {max(f32), max(f32), max(f32)}
	data.bounds_max = {-max(f32), -max(f32), -max(f32)}
	images := make(map[gltf.Integer]int, context.temp_allocator) // glTF image -> index in data.images

	// The default scene, or the first; a file with no scene at all, which is legal, has every
	// mesh at the origin
	scene := file.scene.? or_else 0
	if len(file.scenes) > 0 && int(scene) < len(file.scenes) {
		for root in file.scenes[scene].nodes do gather_gltf_node(file, root, linalg.MATRIX4F32_IDENTITY, &data, &images)
	} else {
		for _, mesh in file.meshes do gather_gltf_mesh(file, gltf.Integer(mesh), linalg.MATRIX4F32_IDENTITY, &data, &images)
	}

	if len(data.parts) == 0 {
		print("Nothing to draw in", path, "(no triangle primitives)")
		destroy_model_data(data)
		return {}, false
	}
	return data, true
}

/*
	One node and everything under it. A glTF node carries a matrix or a translation, rotation
	and scale, never both, and the parser defaults the absent one to the identity, so
	multiplying both in is right either way
*/
@(private)
gather_gltf_node :: proc(file:^gltf.Data, index:gltf.Integer, parent:matrix[4, 4]f32, data:^Model_Data, images:^map[gltf.Integer]int) {
	if int(index) >= len(file.nodes) do return
	node := file.nodes[index]
	world := parent * node.mat * calculate_model_matrix(node.translation, node.rotation, node.scale)
	if mesh, has_mesh := node.mesh.?; has_mesh do gather_gltf_mesh(file, mesh, world, data, images)
	for child in node.children do gather_gltf_node(file, child, world, data, images)
}

/*One mesh's triangle primitives, each becoming a part with `world` baked into its vertices*/
@(private)
gather_gltf_mesh :: proc(file:^gltf.Data, index:gltf.Integer, world:matrix[4, 4]f32, data:^Model_Data, images:^map[gltf.Integer]int) {
	if int(index) >= len(file.meshes) do return

	// Normals are directions: no translation, and under an uneven scale the inverse transpose,
	// or they shear
	normal_matrix := linalg.matrix4_inverse_transpose_f32(world)

	for primitive in file.meshes[index].primitives {
		if primitive.mode != .Triangles do continue

		position_accessor, has_position := primitive.attributes["POSITION"]
		if has_position == false do continue
		positions, positions_ok := read_gltf_vec3(file, position_accessor)
		if positions_ok == false do continue
		count := len(positions)
		if count > 65536 {
			// A Mesh has 16-bit indices because the 3DS and the Vita draw with them
			print("A glTF primitive has", count, "vertices; a part takes at most 65536. Skipped")
			continue
		}

		_, has_normals := primitive.attributes["NORMAL"]
		normals := read_gltf_vec3_optional(file, primitive.attributes, "NORMAL", count)
		uvs := read_gltf_vec2_optional(file, primitive.attributes, "TEXCOORD_0", count)
		colors := read_gltf_color_optional(file, primitive.attributes, "COLOR_0", count)

		part:Model_Data_Part
		part.vertices = make([]Lit_Vertex, count)
		for i in 0 ..< count {
			// Baked now: a node transform is the file's own arrangement, not where the game puts
			// the model, so folding it in leaves a part one buffer and one draw
			position := world * [4]f32{positions[i].x, positions[i].y, positions[i].z, 1}
			normal := normal_matrix * [4]f32{normals[i].x, normals[i].y, normals[i].z, 0}
			part.vertices[i] = Lit_Vertex {
				vertex = {position = position.xyz, uv = uvs[i], color = colors[i]},
				normal = linalg.normalize0(normal.xyz),
			}
			data.bounds_min = linalg.min(data.bounds_min, position.xyz)
			data.bounds_max = linalg.max(data.bounds_max, position.xyz)
		}

		indices, indices_ok := read_gltf_indices(file, primitive, count)
		if indices_ok == false {
			delete(part.vertices)
			continue
		}
		part.indices = indices
		if has_normals == false && split_gltf_flat_normals(&part) == false {
			delete(part.vertices)
			delete(part.indices)
			print("A glTF primitive without normals has", len(indices), "corners; lit flat, a part takes at most 65536. Skipped")
			continue
		}
		read_gltf_material(file, primitive.material, &part, data, images)
		append(&data.parts, part)
	}
}

/*
	glTF says a primitive with no normals is lit flat: every triangle its own face's normal.
	A vertex shared by two triangles can hold only one normal, so each corner becomes a vertex
	of its own (three per triangle) and the indices count straight up. The positions are
	already in the model's space, so the face normal is too. False when that is more vertices
	than a part's 16-bit indices reach
*/
@(private)
split_gltf_flat_normals :: proc(part:^Model_Data_Part) -> bool {
	if len(part.indices) > 65536 do return false
	split := make([]Lit_Vertex, len(part.indices))
	for i := 0; i + 2 < len(part.indices); i += 3 {
		a := part.vertices[part.indices[i]]
		b := part.vertices[part.indices[i + 1]]
		c := part.vertices[part.indices[i + 2]]
		normal := linalg.normalize0(linalg.cross(b.position - a.position, c.position - a.position))
		a.normal, b.normal, c.normal = normal, normal, normal
		split[i], split[i + 1], split[i + 2] = a, b, c
	}
	for &index, i in part.indices do index = u16(i)
	delete(part.vertices)
	part.vertices = split
	return true
}

/*
	A primitive's base colour, texture, alpha mode, sidedness and highlight. A primitive with no
	material is opaque white, single-sided, untextured, with the engine's default highlight
	(mbi.model_settings): glTF's own default material is fully rough and fully metallic, which
	would give no highlight at all to a model that never chose one
*/
@(private)
read_gltf_material :: proc(file:^gltf.Data, material:Maybe(gltf.Integer), part:^Model_Data_Part, data:^Model_Data, images:^map[gltf.Integer]int) {
	part.color = {1, 1, 1, 1}
	part.image = -1
	part.material = mbi.model_settings.default_material
	material_index, has_material := material.?
	if has_material == false || int(material_index) >= len(file.materials) do return
	source := file.materials[material_index]
	// A material without the block has glTF's defaults for it, roughness and metallic 1
	part.material = calculate_material_from_roughness(1, 1)

	if source.double_sided do part.cull = .NONE
	switch source.alpha_mode {
	case .Opaque:
	case .Mask, .Alpha_Cutoff: // the vendored package's two names for glTF's MASK
		part.alpha_cutoff = f32(source.alpha_cutoff)
	case .Blend:
		part.blend = .ALPHA
	}

	pbr, has_pbr := source.metallic_roughness.?
	if has_pbr == false do return
	part.color = pbr.base_color_factor
	part.material = calculate_material_from_roughness(f32(pbr.roughness_factor), f32(pbr.metallic_factor))
	texture, has_texture := pbr.base_color_texture.?
	if has_texture do part.image = find_gltf_image(file, texture.index, data, images)
}

/*
	The image a glTF texture shows, added to data.images the first time it is named, so parts
	sharing a texture share the copy. -1 when the image can't be found as bytes
*/
@(private)
find_gltf_image :: proc(file:^gltf.Data, texture:gltf.Integer, data:^Model_Data, images:^map[gltf.Integer]int) -> int {
	if int(texture) >= len(file.textures) do return -1
	source, has_source := file.textures[texture].source.?
	if has_source == false || int(source) >= len(file.images) do return -1
	if existing, found := images[source]; found do return existing

	// A .gltf keeps an image as a URI (the parser has turned a base64 or a file beside it into
	// bytes); a .glb as a buffer view into its binary chunk. Exactly one is used
	encoded, is_bytes := file.images[source].uri.([]byte)
	if is_bytes == false do encoded, is_bytes = read_gltf_image_view(file, source)
	if is_bytes == false {
		print("A model texture could not be found; that part draws untextured")
		return -1
	}

	index := len(data.images)
	append(&data.images, make([]u8, len(encoded)))
	copy(data.images[index], encoded)
	images[source] = index
	return index
}

@(private)
read_gltf_image_view :: proc(file:^gltf.Data, source:gltf.Integer) -> (bytes:[]byte, ok:bool) {
	view_index := file.images[source].buffer_view.? or_return
	if int(view_index) >= len(file.buffer_views) do return nil, false
	view := file.buffer_views[view_index]
	if int(view.buffer) >= len(file.buffers) do return nil, false
	buffer := file.buffers[view.buffer].uri.([]byte) or_return
	start := int(view.byte_offset)
	end := start + int(view.byte_length)
	if end > len(buffer) do return nil, false
	return buffer[start:end], true
}

/*
	Where one accessor's elements start, how far apart they are, and how many. A buffer view's
	`byteStride`, when given, is the step between elements; otherwise the element's own size
*/
@(private)
read_gltf_accessor :: proc(file:^gltf.Data, index:gltf.Integer) -> (bytes:[]byte, stride, count:int, ok:bool) {
	if int(index) >= len(file.accessors) do return
	accessor := file.accessors[index]
	if _, sparse := accessor.sparse.?; sparse {
		print("Sparse glTF accessors are not read; that primitive is skipped")
		return
	}
	view_index := accessor.buffer_view.? or_return
	if int(view_index) >= len(file.buffer_views) do return
	view := file.buffer_views[view_index]
	if int(view.buffer) >= len(file.buffers) do return
	buffer := file.buffers[view.buffer].uri.([]byte) or_return

	element := calculate_gltf_component_size(accessor.component_type) * calculate_gltf_component_count(accessor.type)
	stride = int(view.byte_stride.? or_else gltf.Integer(element))
	count = int(accessor.count)
	start := int(accessor.byte_offset) + int(view.byte_offset)
	if count == 0 || start + (count - 1) * stride + element > len(buffer) do return nil, 0, 0, false
	return buffer[start:], stride, count, true
}

@(private)
calculate_gltf_component_size :: proc(type:gltf.Component_Type) -> int {
	switch type {
	case .Byte, .Unsigned_Byte: return 1
	case .Short, .Unsigned_Short: return 2
	case .Unsigned_Int, .Float: return 4
	}
	return 0
}

@(private)
calculate_gltf_component_count :: proc(type:gltf.Accessor_Type) -> int {
	switch type {
	case .Scalar: return 1
	case .Vector2: return 2
	case .Vector3: return 3
	case .Vector4: return 4
	case .Matrix2: return 4
	case .Matrix3: return 9
	case .Matrix4: return 16
	}
	return 0
}

/*Three floats per element: what glTF requires of positions and normals. Temp-allocated*/
@(private)
read_gltf_vec3 :: proc(file:^gltf.Data, index:gltf.Integer) -> (values:[][3]f32, ok:bool) {
	bytes, stride, count := read_gltf_accessor(file, index) or_return
	if file.accessors[index].component_type != .Float do return nil, false
	values = make([][3]f32, count, context.temp_allocator)
	for i in 0 ..< count do values[i] = (cast(^[3]f32)&bytes[i * stride])^
	return values, true
}

/*A NORMAL that isn't there is legal, and gather_gltf_mesh lights it flat; up is filled in meanwhile, and stays only for one that can't be read*/
@(private)
read_gltf_vec3_optional :: proc(file:^gltf.Data, attributes:map[string]gltf.Integer, name:string, count:int) -> [][3]f32 {
	if index, present := attributes[name]; present {
		if values, ok := read_gltf_vec3(file, index); ok && len(values) >= count do return values
	}
	values := make([][3]f32, count, context.temp_allocator)
	for &value in values do value = {0, 1, 0}
	return values
}

/*
	Texture coordinates: floats, or bytes or shorts spread over the whole range of their type.
	glTF's are 0 at the image's top, as Matchbox's are, so they go in unchanged. All zero when
	absent: the part's colour alone shows
*/
@(private)
read_gltf_vec2_optional :: proc(file:^gltf.Data, attributes:map[string]gltf.Integer, name:string, count:int) -> [][2]f32 {
	values := make([][2]f32, count, context.temp_allocator)
	index, present := attributes[name]
	if present == false do return values
	bytes, stride, available, ok := read_gltf_accessor(file, index)
	if ok == false do return values
	for i in 0 ..< min(count, available) {
		at := &bytes[i * stride]
		#partial switch file.accessors[index].component_type {
		case .Float: values[i] = (cast(^[2]f32)at)^
		case .Unsigned_Byte: values[i] = {f32((cast(^[2]u8)at)[0]) / 255, f32((cast(^[2]u8)at)[1]) / 255}
		case .Unsigned_Short: values[i] = {f32((cast(^[2]u16)at)[0]) / 65535, f32((cast(^[2]u16)at)[1]) / 65535}
		}
	}
	return values
}

/*
	Vertex colours: three or four components, floats or normalised bytes or shorts. White when
	absent, so the material's colour and texture are what shows
*/
@(private)
read_gltf_color_optional :: proc(file:^gltf.Data, attributes:map[string]gltf.Integer, name:string, count:int) -> [][4]f32 {
	values := make([][4]f32, count, context.temp_allocator)
	for &value in values do value = {1, 1, 1, 1}
	index, present := attributes[name]
	if present == false do return values
	bytes, stride, available, ok := read_gltf_accessor(file, index)
	if ok == false do return values
	components := calculate_gltf_component_count(file.accessors[index].type)
	if components != 3 && components != 4 do return values
	for i in 0 ..< min(count, available) {
		at := &bytes[i * stride]
		for c in 0 ..< components {
			#partial switch file.accessors[index].component_type {
			case .Float: values[i][c] = (cast([^]f32)at)[c]
			case .Unsigned_Byte: values[i][c] = f32((cast([^]u8)at)[c]) / 255
			case .Unsigned_Short: values[i][c] = f32((cast([^]u16)at)[c]) / 65535
			}
		}
	}
	return values
}

/*
	A primitive's indices as u16. glTF stores bytes, shorts or ints; a u32 index above 65535
	can't be, since the part already has at most 65536 vertices. No indices at all is legal and
	means the vertices are already in order
*/
@(private)
read_gltf_indices :: proc(file:^gltf.Data, primitive:gltf.Mesh_Primitive, vertex_count:int) -> (indices:[]u16, ok:bool) {
	index, present := primitive.indices.?
	if present == false {
		indices = make([]u16, vertex_count)
		for i in 0 ..< vertex_count do indices[i] = u16(i)
		return indices, true
	}
	bytes, stride, count := read_gltf_accessor(file, index) or_return
	indices = make([]u16, count)
	for i in 0 ..< count {
		at := &bytes[i * stride]
		value:u32
		#partial switch file.accessors[index].component_type {
		case .Unsigned_Byte: value = u32((cast(^u8)at)^)
		case .Unsigned_Short: value = u32((cast(^u16)at)^)
		case .Unsigned_Int: value = (cast(^u32)at)^
		case:
			delete(indices)
			return nil, false
		}
		if int(value) >= vertex_count {
			print("A glTF index points past its primitive's vertices; that primitive is skipped")
			delete(indices)
			return nil, false
		}
		indices[i] = u16(value)
	}
	return indices, true
}
