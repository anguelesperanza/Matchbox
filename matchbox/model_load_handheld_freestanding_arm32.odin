#+build freestanding arm32

package matchbox

/*
	Model -- loading (3DS and Vita)
	===============================
	The consoles read the .mbm the build made from each glTF in assets/models (tools/modelpack.odin,
	model_file.odin), never glTF itself. Its images were written beside it as ordinary images, so
	they come in through load_texture like any other: a .t3x on the 3DS, a PNG on the Vita.

	One file for both consoles, outside `when VITA` / `when !VITA` like the other handheld files
	that are the same on both: get_asset and read_file_bytes have the same name and shape on each
*/

/*
	A model from `filename` in the assets' `models/` folder, named as on PC ("crate.glb"); the
	build has turned it into models/crate.mbm. Stops with a message when the file is missing or
	isn't a model file the build wrote: a model that half-loaded would draw nothing with no sign
	why. `filter` is how its textures are sampled, as on PC
*/
load_model :: proc(filename:string, filter:Filter_Mode = .POINT) -> (model:Model) {
	path_buffer:[256]u8
	path, path_ok := get_asset(path_buffer[:], filename, .MODEL)
	ensure(path_ok, "Model path is too long")

	bytes := read_file_bytes(path)
	if bytes == nil {
		print("No such model:", path, "(the build makes it from assets/models; was the model there?)")
		panic("Failed to load model")
	}
	defer delete(bytes)

	data, ok, problem := read_model_file(bytes)
	defer destroy_model_data(data)
	if ok == false {
		print("Could not read", path, "--", problem)
		panic("Failed to load model")
	}

	textures := make([]Texture, len(data.image_names))
	for name, index in data.image_names do textures[index] = load_texture(name, filter)
	return create_model_from_data(data, textures)
}
