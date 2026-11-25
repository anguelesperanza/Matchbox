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
		"MBM1", u32 version (2)
		u32 part count, u32 image count
		[3]f32 bounds_min, [3]f32 bounds_max
		per image: u16 name length, the name (an image asset name, e.g. "models/crate_0.png"),
		           padded to 4 bytes
		per part:  u32 vertex count, u32 index count, [4]f32 colour, i32 image (-1 for none),
		           u8 blend (0 none, 1 alpha), u8 cull (0 back, 1 none), u16 0, f32 alpha cutoff,
		           f32 shininess, f32 specular strength (the Material),
		           the vertices as Lit_Vertex (48 bytes each), the indices (u16 each),
		           padded to 4 bytes
	Images are names, not bytes: the build writes each beside the model as its own image, so
	each target's usual image path converts it (tritex for the 3DS) and load_texture reads it.

	Version 2 (G2 L4-2) stores each vertex whole with its normal, as create_lit_mesh uploads it,
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
}

/*Frees what read_gltf_model or read_model_file made*/
destroy_model_data :: proc(data:Model_Data) {
	for part in data.parts {
		delete(part.vertices)
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
		write_value(&out, u32(len(part.vertices)))
		write_value(&out, u32(len(part.indices)))
		write_value(&out, part.color)
		write_value(&out, i32(part.image))
		write_value(&out, u8(1) if part.blend == .ALPHA else u8(0))
		write_value(&out, u8(1) if part.cull == .NONE else u8(0))
		write_value(&out, u16(0))
		write_value(&out, part.alpha_cutoff)
		write_value(&out, part.material.shininess)
		write_value(&out, part.material.specular_strength)
		append(&out, ..mem.slice_to_bytes(part.vertices))
		append(&out, ..mem.slice_to_bytes(part.indices))
		pad_to_four(&out)
	}
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
		_ = read_value(&reader, u16)
		part.alpha_cutoff = read_value(&reader, f32)
		part.material.shininess = read_value(&reader, f32)
		part.material.specular_strength = read_value(&reader, f32)
		part.vertices = read_slice(&reader, Lit_Vertex, vertex_count)
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
	return data, true, ""
}

/*
	The version of the layout above, written into every file and checked on every read. A
	procedure rather than a package constant (CLAUDE.md), the one place both sides ask
*/
@(private = "file")
get_model_file_version :: proc() -> u32 {
	return 2
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
