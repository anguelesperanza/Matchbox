package modelpack

/*
	modelpack: glTF to Matchbox's .mbm, for the 3DS and the Vita
	============================================================
	Build:  odin build tools/modelpack.odin -file -out:tools/modelpack.exe
	Use:    modelpack <model.gltf|.glb> <model_folder> <image_folder>

	Writes <model_folder>/<name>.mbm and, for each image the model uses, <image_folder>/models/
	<name>_<n>.png. The .mbm names those images as "models/<name>_<n>.png", an image asset name,
	so each console's build treats them like any other image (tritex makes the 3DS's .t3x) and
	the console's load_model loads them with load_texture. 3ds_build.bat and vita_build.bat run
	this for every model in assets\models before they convert images.

	The glTF is read by Matchbox's own reader (read_gltf_model, model_load_windows.odin), the one
	the PC's load_model uses, so a model can't mean one thing on PC and another on a console.
	Every image is decoded and written again as a PNG, whatever the glTF held (PNG or JPEG):
	tritex and the Vita's libpng then only ever see PNGs
*/

import "core:fmt"
import "core:image"
import "core:image/jpeg"
import "core:image/png"
import "core:os"
import "core:path/filepath"

import mb "../matchbox"

_ :: jpeg // registers the JPEG decoder with core:image

main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: modelpack <model.gltf|.glb> <model_folder> <image_folder>")
		os.exit(2)
	}
	input, model_folder, image_folder := os.args[1], os.args[2], os.args[3]
	name := filepath.stem(input)

	data, ok := mb.read_gltf_model(input)
	if ok == false {
		fmt.eprintln("modelpack: could not read", input)
		os.exit(1)
	}
	defer mb.destroy_model_data(data)

	names := make([]string, len(data.images))
	image_directory, _ := filepath.join({image_folder, "models"})
	os.make_directory_all(image_directory)
	for encoded, index in data.images {
		names[index] = fmt.aprintf("models/%s_%d.png", name, index)
		decoded, decode_error := image.load_from_bytes(encoded, options = {.alpha_add_if_missing})
		if decode_error != nil {
			fmt.eprintln("modelpack:", input, "image", index, "could not be decoded:", decode_error)
			os.exit(1)
		}
		path, _ := filepath.join({image_directory, fmt.tprintf("%s_%d.png", name, index)})
		if save_error := png.save_to_file(path, decoded); save_error != nil {
			fmt.eprintln("modelpack: could not write", path, save_error)
			os.exit(1)
		}
		image.destroy(decoded)
	}

	bytes := mb.write_model_file(data, names)
	os.make_directory_all(model_folder)
	model_path, _ := filepath.join({model_folder, fmt.tprintf("%s.mbm", name)})
	if write_error := os.write_entire_file(model_path, bytes); write_error != nil {
		fmt.eprintln("modelpack: could not write", model_path, write_error)
		os.exit(1)
	}

	vertices := 0
	for part in data.parts do vertices += len(part.vertices)
	fmt.printfln(" - %s: %d parts, %d vertices, %d images", name, len(data.parts), vertices, len(data.images))
}
