package matchbox

/*
	Model file (.mbm)
	=================
	The model format the 3DS and the Vita read. The build turns each glTF in assets/models into
	one (tools/modelpack.odin), so the consoles never parse JSON: no parse time and no heap spike
	at load, and a smaller file in romfs (render_plan.md, G1). The PC reads glTF directly
	(model_load_windows.odin); both arrive at the same Model_Data, so a model means the same on
	every target.

	Shared and free of file I/O, so the PC's tests check that what is written reads back.

	Layout, little-endian, as every Matchbox target is, so values are copied as they are:
		"MBM1", u32 version (3)
		u32 part count, u32 image count
		[3]f32 bounds_min, [3]f32 bounds_max
		per image: u16 name length, the name (an image asset name, e.g. "models/crate_0.png"),
		           padded to 4 bytes
		per part:  u32 vertex count, u32 index count, [4]f32 colour, i32 image (-1 for none),
		           u8 blend (0 none, 1 alpha), u8 cull (0 back, 1 none), u8 skinned, u8 0, f32 alpha cutoff,
		           f32 shininess, f32 specular strength (the Material),
		           a skinned part only: i32 skin, i32 mesh node, u32 joint count, the joint map (u32 each),
		           the vertices as Lit_Vertex (48 bytes each), or Skinned_Vertex (56) when skinned,
		           the indices (u16 each), padded to 4 bytes
		the skeleton (G6): u32 node count, u32 skin count, u32 clip count, then per node i32 parent,
		           [3]f32 position, [4]f32 rotation, [3]f32 scale, u16 name length, the name, padded;
		           per skin u32 joint count, the joints (u32), their inverse binds (16 f32 each);
		           per clip u16 name length, the name, padded, f32 duration, u32 track count, per track
		           u32 node, u8 path, u8 interpolation, u16 0, u32 time count, the times, u32 vector count,
		           the vectors ([3]f32), u32 quaternion count, the quaternions ([4]f32)
	Images are names, not bytes: the build writes each beside the model as its own image, so
	each target's usual image path converts it (tritex for the 3DS) and load_texture reads it.

	Version 3 (G6) adds the skeleton and clips and the skinned part, which carries a joint map so the
	loader's split into at most a target's joint limit survives into the file (the 3DS file is cut
	for 22, the Vita's for 64: tools/modelpack takes the limit). Version 2 (G2 L4-2) stores each vertex whole with its normal, as create_lit_mesh uploads it,
	where version 1 kept the normals in a run of their own after the vertices; and the
	material. Version 1 is refused rather than read: the build makes every .mbm from its glTF
	each time, so an old one only means a stale build
*/

import "core:mem"

/*One primitive of a model, on the CPU, in the model's own space*/
Model_Data_Part :: struct {
	vertices:[]Lit_Vertex,
	indices:[]u16,
	material:Material,
	color:[4]f32, // the material's base colour factor
	image:int, // index into the model's images, or -1 for no texture
	blend:Blend_Mode,
	alpha_cutoff:f32,
	cull:Cull_Mode,

	// A skinned part (G6) keeps its vertices in `skinned_vertices` and leaves `vertices` nil
	skinned_vertices:[]Skinned_Vertex,
	skin:int, // which of the model's skins deforms it
	mesh_node:int, // the node its mesh hangs off, -1 for none
	joint_map:[]u32, // the skin's joints its vertices use, in the order their `joints` name them
}

/*
	A whole model on the CPU. Read from glTF, `images` hold the encoded files (PNG or JPEG); read
	from a .mbm, `image_names` hold the asset names of the images the build wrote beside it
*/
Model_Data :: struct {
	parts:[dynamic]Model_Data_Part,
	images:[dynamic][]u8,
	image_names:[dynamic]string,
	bounds_min:[3]f32,
	bounds_max:[3]f32,
	skeleton:Skeleton, // empty for a model with none (skeleton.odin)
	animations:[]Model_Animation,
}

/*Frees what read_gltf_model or read_model_file made, all of it. After create_model_from_data use destroy_model_data_leftovers*/
destroy_model_data :: proc(data:Model_Data) {
	for part in data.parts do delete(part.joint_map)
	destroy_skeleton(data.skeleton)
	destroy_model_animations(data.animations)
	destroy_model_data_leftovers(data)
}

/*
	What is still the caller's once create_model_from_data has run: the CPU copies of the vertices and indices
	and the images. The skeleton, the clips and the joint maps went into the Model, which frees them
*/
destroy_model_data_leftovers :: proc(data:Model_Data) {
	for part in data.parts {
		delete(part.vertices)
		delete(part.skinned_vertices)
		delete(part.indices)
	}
	for encoded in data.images do delete(encoded)
	for name in data.image_names do delete(name)
	delete(data.parts)
	delete(data.images)
	delete(data.image_names)
}

/*
	`data` as the bytes of a .mbm, with `image_names` (one per image, in order) standing for its
	images. The caller deletes the result
*/
write_model_file :: proc(data:Model_Data, image_names:[]string) -> []u8 {
	assert(len(image_names) == len(data.images) || len(data.images) == 0, "One name per image")
	out := make([dynamic]u8)
	write_bytes(&out, transmute([4]u8)u32(0x314D424D)) // "MBM1"
	write_value(&out, get_model_file_version())
	write_value(&out, u32(len(data.parts)))
	write_value(&out, u32(len(image_names)))
	write_value(&out, data.bounds_min)
	write_value(&out, data.bounds_max)
	for name in image_names {
		write_value(&out, u16(len(name)))
		append(&out, ..transmute([]u8)name)
		pad_to_four(&out)
	}
	for part in data.parts {
		write_value(&out, u32(len(part.skinned_vertices) if len(part.skinned_vertices) > 0 else len(part.vertices)))
		write_value(&out, u32(len(part.indices)))
		write_value(&out, part.color)
		write_value(&out, i32(part.image))
		write_value(&out, u8(1) if part.blend == .ALPHA else u8(0))
		write_value(&out, u8(1) if part.cull == .NONE else u8(0))
		skinned := len(part.skinned_vertices) > 0
		write_value(&out, u8(1) if skinned else u8(0))
		write_value(&out, u8(0))
		write_value(&out, part.alpha_cutoff)
		write_value(&out, part.material.shininess)
		write_value(&out, part.material.specular_strength)
		if skinned {
				write_value(&out, i32(part.skin))
				write_value(&out, i32(part.mesh_node))
				write_value(&out, u32(len(part.joint_map)))
				append(&out, ..mem.slice_to_bytes(part.joint_map))
				append(&out, ..mem.slice_to_bytes(part.skinned_vertices))
		} else {
				append(&out, ..mem.slice_to_bytes(part.vertices))
		}
		append(&out, ..mem.slice_to_bytes(part.indices))
		pad_to_four(&out)
	}
	write_skeleton(&out, data)
	return out[:]
}

/*
	The model a .mbm holds. `ok` is false, with `problem` saying why, for anything that isn't a
	whole version-2 file: a model that half-read would draw garbage with no sign why. Every array
	is copied out rather than pointed into `bytes`, which may be freed after, and which on ARM may
	not be aligned for the floats inside it. Free the result with destroy_model_data
*/
read_model_file :: proc(bytes:[]u8) -> (data:Model_Data, ok:bool, problem:string) {
	reader := Model_File_Reader{bytes = bytes}
	magic := read_value(&reader, u32)
	if reader.failed || magic != 0x314D424D do return {}, false, "not a Matchbox model file"
	version := read_value(&reader, u32)
	if version != get_model_file_version() do return {}, false, "a model file version this Matchbox does not read: rebuild it"
	part_count := int(read_value(&reader, u32))
	image_count := int(read_value(&reader, u32))
	data.bounds_min = read_value(&reader, [3]f32)
	data.bounds_max = read_value(&reader, [3]f32)

	for _ in 0 ..< image_count {
		length := int(read_value(&reader, u16))
		name := read_slice(&reader, u8, length)
		skip_to_four(&reader)
		if reader.failed do break
		append(&data.image_names, string(name))
	}
	for _ in 0 ..< part_count {
		part:Model_Data_Part
		vertex_count := int(read_value(&reader, u32))
		index_count := int(read_value(&reader, u32))
		part.color = read_value(&reader, [4]f32)
		part.image = int(read_value(&reader, i32))
		part.blend = .ALPHA if read_value(&reader, u8) == 1 else .NONE
		part.cull = .NONE if read_value(&reader, u8) == 1 else .BACK
		skinned := read_value(&reader, u8) == 1
		_ = read_value(&reader, u8)
		part.alpha_cutoff = read_value(&reader, f32)
		part.material.shininess = read_value(&reader, f32)
		part.material.specular_strength = read_value(&reader, f32)
		if skinned {
			part.skin = int(read_value(&reader, i32))
			part.mesh_node = int(read_value(&reader, i32))
			part.joint_map = read_slice(&reader, u32, int(read_value(&reader, u32)))
			part.skinned_vertices = read_slice(&reader, Skinned_Vertex, vertex_count)
			// A vertex names a slot of the part's own joint map: one past it would read another draw's palette on the GPU
			for vertex in part.skinned_vertices {
				for slot in 0 ..< 4 {
					if int(vertex.joints[slot]) >= len(part.joint_map) do reader.failed = true
				}
			}
		} else {
			part.vertices = read_slice(&reader, Lit_Vertex, vertex_count)
		}
		part.indices = read_slice(&reader, u16, index_count)
		skip_to_four(&reader)
		append(&data.parts, part) // appended even when short, so destroy_model_data frees it
		if reader.failed do break
		if part.image >= image_count do reader.failed = true
		for index in part.indices {
			if int(index) >= vertex_count do reader.failed = true
		}
	}
	if reader.failed {
		destroy_model_data(data)
		return {}, false, "the model file is cut short or names things it doesn't have"
	}
	if read_skeleton(&reader, &data) == false {
		destroy_model_data(data)
		return {}, false, "the model file's skeleton is cut short or names things it doesn't have"
	}
	return data, true, ""
}

/*
	The version of the layout above, written into every file and checked on every read. A
	procedure rather than a package constant (CLAUDE.md), the one place both sides ask
*/
@(private = "file")
get_model_file_version :: proc() -> u32 {
	return 3
}

@(private = "file")
Model_File_Reader :: struct {
	bytes:[]u8,
	at:int,
	failed:bool, // set once anything runs past the end; every read after it gives zero
}

@(private = "file")
read_value :: proc(reader:^Model_File_Reader, $T:typeid) -> (value:T) {
	if reader.failed || reader.at + size_of(T) > len(reader.bytes) {
		reader.failed = true
		return
	}
	mem.copy(&value, &reader.bytes[reader.at], size_of(T))
	reader.at += size_of(T)
	return
}

@(private = "file")
read_slice :: proc(reader:^Model_File_Reader, $T:typeid, count:int) -> []T {
	size := count * size_of(T)
	if reader.failed || count < 0 || reader.at + size > len(reader.bytes) {
		reader.failed = true
		return nil
	}
	values := make([]T, count)
	if size > 0 do mem.copy(raw_data(values), &reader.bytes[reader.at], size)
	reader.at += size
	return values
}

@(private = "file")
skip_to_four :: proc(reader:^Model_File_Reader) {
	reader.at = (reader.at + 3) &~ 3
}

@(private = "file")
write_value :: proc(out:^[dynamic]u8, value:$T) {
	value := value
	append(out, ..mem.ptr_to_bytes(&value))
}

@(private = "file")
write_bytes :: proc(out:^[dynamic]u8, value:[4]u8) {
	value := value
	append(out, ..value[:])
}

@(private = "file")
pad_to_four :: proc(out:^[dynamic]u8) {
	for len(out) % 4 != 0 do append(out, 0)
}

/*The skeleton and the clips, after the parts. Positions, rotations and scales go field by field: a Transform has padding in it*/
@(private = "file")
write_skeleton :: proc(out:^[dynamic]u8, data:Model_Data) {
	skeleton := data.skeleton
	write_value(out, u32(len(skeleton.rest)))
	write_value(out, u32(len(skeleton.skins)))
	write_value(out, u32(len(data.animations)))

	for node in 0 ..< len(skeleton.rest) {
		write_value(out, skeleton.parents[node])
		rest := skeleton.rest[node]
		write_value(out, rest.position)
		write_value(out, [4]f32{imag(rest.rotation), jmag(rest.rotation), kmag(rest.rotation), real(rest.rotation)})
		write_value(out, rest.scale)
		write_name(out, skeleton.names[node])
	}
	for skin in skeleton.skins {
		write_value(out, u32(len(skin.joints)))
		append(out, ..mem.slice_to_bytes(skin.joints))
		append(out, ..mem.slice_to_bytes(skin.inverse_bind))
	}
	for clip in data.animations {
		write_name(out, clip.name)
		write_value(out, clip.duration)
		write_value(out, u32(len(clip.tracks)))
		for track in clip.tracks {
			write_value(out, track.node)
			write_value(out, u8(track.path))
			write_value(out, u8(track.interpolation))
			write_value(out, u16(0))
			write_value(out, u32(len(track.times)))
			append(out, ..mem.slice_to_bytes(track.times))
			write_value(out, u32(len(track.vectors)))
			append(out, ..mem.slice_to_bytes(track.vectors))
			write_value(out, u32(len(track.quats)))
			for quat in track.quats {
				write_value(out, [4]f32{imag(quat), jmag(quat), kmag(quat), real(quat)})
			}
		}
	}
}

@(private = "file")
write_name :: proc(out:^[dynamic]u8, name:string) {
	write_value(out, u16(len(name)))
	append(out, ..transmute([]u8)name)
	pad_to_four(out)
}

@(private = "file")
read_name :: proc(reader:^Model_File_Reader) -> string {
	length := int(read_value(reader, u16))
	bytes := read_slice(reader, u8, length)
	skip_to_four(reader)
	return string(bytes)
}

@(private = "file")
read_skeleton :: proc(reader:^Model_File_Reader, data:^Model_Data) -> bool {
	node_count := int(read_value(reader, u32))
	skin_count := int(read_value(reader, u32))
	clip_count := int(read_value(reader, u32))
	if reader.failed do return false
	// A count a short file cannot back is refused before anything is made for it
	if node_count > len(reader.bytes) || skin_count > len(reader.bytes) || clip_count > len(reader.bytes) do return false

	skeleton := &data.skeleton
	if node_count > 0 {
		skeleton.parents = make([]i32, node_count)
		skeleton.rest = make([]Transform, node_count)
		skeleton.names = make([]string, node_count)
		skeleton.skins = make([]Model_Skin, skin_count)
	}
	for node in 0 ..< node_count {
		skeleton.parents[node] = read_value(reader, i32)
		rest := Transform{}
		rest.position = read_value(reader, [3]f32)
		quat := read_value(reader, [4]f32)
		rest.rotation = quaternion(x = quat.x, y = quat.y, z = quat.z, w = quat.w)
		rest.scale = read_value(reader, [3]f32)
		skeleton.rest[node] = rest
		skeleton.names[node] = read_name(reader)
		if reader.failed do return false
		if int(skeleton.parents[node]) >= node_count do return false
	}
	for &skin in skeleton.skins {
		count := int(read_value(reader, u32))
		skin.joints = read_slice(reader, u32, count)
		skin.inverse_bind = read_slice(reader, matrix[4, 4]f32, count)
		if reader.failed do return false
		for joint in skin.joints do if int(joint) >= node_count do return false
	}
	if node_count > 0 do skeleton.order = calculate_skeleton_order(skeleton.parents)

	if clip_count > 0 do data.animations = make([]Model_Animation, clip_count)
	for &clip in data.animations {
		clip.name = read_name(reader)
		clip.duration = read_value(reader, f32)
		track_count := int(read_value(reader, u32))
		if reader.failed || track_count > len(reader.bytes) do return false
		clip.tracks = make([]Animation_Track, track_count)
		for &track in clip.tracks {
			track.node = read_value(reader, u32)
			track.path = Animation_Path(read_value(reader, u8))
			track.interpolation = Animation_Interpolation(read_value(reader, u8))
			_ = read_value(reader, u16)
			track.times = read_slice(reader, f32, int(read_value(reader, u32)))
			track.vectors = read_slice(reader, [3]f32, int(read_value(reader, u32)))
			quat_count := int(read_value(reader, u32))
			if quat_count > 0 && reader.failed == false {
				packed := read_slice(reader, [4]f32, quat_count)
				track.quats = make([]quaternion128, len(packed))
				for quat, index in packed do track.quats[index] = quaternion(x = quat.x, y = quat.y, z = quat.z, w = quat.w)
				delete(packed)
			}
			if reader.failed do return false
			if int(track.node) >= node_count || int(track.path) > int(Animation_Path.SCALE) || int(track.interpolation) > int(Animation_Interpolation.CUBIC) do return false
		}
	}
	return reader.failed == false
}
