#+build windows

package matchbox

/*
	Texture
	=======
	Creates / Loads images onto the GPU from the assets folder

	uses core:image for image decoding
*/

import win "core:sys/windows"
import "core:os"
import "core:strings"
import "core:image"
import "core:image/png"

import "vendor:directx/d3d11"



load_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {

	path := get_asset(filename, .IMAGE)
	meta, meta_found := load_texture_meta(path)

	loaded_image, err := image.load_from_file(path, options = {.alpha_add_if_missing})
	ensure(err == nil, "Failed to load image") // Might change to a checkered pattern if no image is loaded
	ensure(loaded_image.depth == 8 && loaded_image.channels == 4, "Texutres must be 8 bits per channel")
	

	texture = create_texture_from_pixels(raw_data(loaded_image.pixels), i32(loaded_image.width), i32(loaded_image.height), filter)

	texture.pixels_per_unit = meta.pixels_per_unit
	texture.source_pixels_per_unit = meta.source_pixels_per_unit
	texture.columns = meta.columns
	texture.rows = meta.rows
	texture.frame_count = meta.frame_count
	if meta_found == false {
		texture.guessed_meta = calculate_guessed_texture_meta(loaded_image.pixels[:], texture.width, texture.height)
	}

	ensure(texture.width % texture.columns == 0 && texture.height % texture.rows == 0, "Texture size must divide evenly into its columns and rows")

	image.destroy(loaded_image)
	delete(path)

	return
	
}

/*
	Puts RGBA pixels (8 bits per channel, `width * 4` bytes a row) on the GPU.

	For pictures made at run time, like a font atlas. There is no file, so no .meta:
	one frame, one pixel per unit. The caller owns `pixels` and can free them afterwards.
*/
create_texture_from_pixels :: proc(pixels:rawptr, width, height:i32, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
	description := d3d11.TEXTURE2D_DESC {
		Width = cast(u32)width,
		Height = cast(u32)height,
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
		SampleDesc = {Count = 1},
	}

	data := d3d11.SUBRESOURCE_DATA {
		pSysMem = pixels,
		SysMemPitch = u32(width * 4), // bytes in one row
	}

	result := mbi.device->CreateTexture2D(&description, &data, &texture.texture)
	ensure(win.SUCCEEDED(result), "Create texture failed")

	result = mbi.device->CreateShaderResourceView(texture.texture, nil, &texture.view)
	ensure(win.SUCCEEDED(result), "Create texture view failed")

	texture.filter = filter
	texture.width = width
	texture.height = height

	meta := default_texture_meta()
	texture.pixels_per_unit = meta.pixels_per_unit
	texture.source_pixels_per_unit = meta.source_pixels_per_unit
	texture.columns = meta.columns
	texture.rows = meta.rows
	texture.frame_count = meta.frame_count
	return
}

/*Reads `name.meta` from next to the image. No file means the defaults (ppu 1, one frame) and `found` false*/
@(private)
load_texture_meta :: proc(image_path:string) -> (meta:Texture_Meta, found:bool) {
	extension_start := strings.last_index_byte(image_path, '.')
	if extension_start < 0 {
		return default_texture_meta(), false
	}

	meta_path := strings.concatenate({image_path[:extension_start], ".meta"})
	defer delete(meta_path)

	if os.is_file(meta_path) == false {
		return default_texture_meta(), false
	}

	bytes, read_err := os.read_entire_file(meta_path, context.allocator)
	ensure(read_err == nil, "Could not read the .meta file")
	defer delete(bytes)

	error:string
	line:int
	meta, error, line = parse_texture_meta(string(bytes))
	if error != "" {
		print(meta_path, "line", line, ":", error)
		panic("Bad .meta file")
	}
	return meta, true
}


destroy_texture :: proc(texture:Texture) {
	if texture.view != nil do texture.view->Release()
	if texture.texture != nil do texture.texture->Release()
}
