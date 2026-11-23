#+build freestanding arm32

package matchbox

/*
	Texture -- Vita
	===============
	Loads the game's PNGs as they are: vita_build.bat packs assets\images into app0:/assets/
	images unchanged, and libpng (gfx.load_png) decodes them on the console. Same procedures as
	texture_windows.odin and texture_3ds_freestanding_arm32.odin.

	A GXM linear texture is the image's rows top first, each padded to a multiple of 8 pixels,
	so unlike the 3DS there is no canvas and no flip: the shared 0..1, v-down coordinates are
	the GPU's own, and render_item passes them through.

	Inside `when VITA` for the reason in backend_vita_freestanding_arm32.odin
*/

import "core:mem"

import "vito/gfx"
import "vito/sce"
import "vito/vito"

when VITA {

	/*
		The image `filename` names in the assets folder: assets/images/hero.png is
		app0:/assets/images/hero.png, and its .meta, if it has one, sits next to it. Subfolders
		are kept, as on PC
	*/
	load_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		path_buffer:[256]u8
		path, path_ok := get_asset(path_buffer[:], filename, .IMAGE)
		ensure(path_ok, "Image path is too long")

		bytes, read_ok := vito.read_entire_file(path)
		if read_ok == false {
			print("No such image:", path)
			panic("Failed to load image")
		}
		defer delete(bytes)

		// The gfx.Texture lives on the heap: Texture is copied by value into every sprite and
		// queued draw, and they must all name the one GPU texture, as on the 3DS
		texture.texture = new(gfx.Texture)
		ok:bool
		texture.texture^, ok = gfx.load_png(bytes, calculate_gxm_filter(filter), .CLAMP)
		if ok == false {
			print("Not a PNG libpng can read:", path, "--", string(cstring(&gfx.last_png_error[0])))
			panic("Failed to load image")
		}
		texture.width = i32(texture.texture.width)
		texture.height = i32(texture.texture.height)
		texture.filter = filter
		ensure(texture.width <= 4096 && texture.height <= 4096, "The Vita takes textures up to 4096 pixels a side")

		meta, meta_found := load_texture_meta(filename)
		texture.pixels_per_unit = meta.pixels_per_unit
		texture.source_pixels_per_unit = meta.source_pixels_per_unit
		texture.columns = meta.columns
		texture.rows = meta.rows
		texture.frame_count = meta.frame_count
		if meta_found == false {
			// The guess reads plain rows, so the padding at the end of each is left out.
			// Only for images with no .meta, and only once, at load
			pixels := read_texture_pixels(texture)
			texture.guessed_meta = calculate_guessed_texture_meta(pixels, texture.width, texture.height)
			delete(pixels)
		}

		ensure(texture.width % texture.columns == 0 && texture.height % texture.rows == 0, "Texture size must divide evenly into its columns and rows")
		return
	}

	/*
		Puts RGBA pixels (8 bits per channel, `width * 4` bytes a row) on the GPU. RGBA8 is
		already the byte order of GXM's U8U8U8U8_ABGR, so each row is copied as it is.
		The caller owns `pixels` and can free them afterwards
	*/
	create_texture_from_pixels :: proc(pixels:rawptr, width, height:i32, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		ensure(width > 0 && height > 0, "A texture needs a size")
		ensure(width <= 4096 && height <= 4096, "The Vita takes textures up to 4096 pixels a side")

		texture.texture = new(gfx.Texture)
		ok:bool
		texture.texture^, ok = gfx.create_texture(int(width), int(height), calculate_gxm_filter(filter), .CLAMP)
		ensure(ok, "Out of video memory for a texture")

		source := ([^]u8)(pixels)
		for y in 0 ..< int(height) {
			mem.copy(&texture.texture.pixels[y * texture.texture.stride], &source[y * int(width) * 4], int(width) * 4)
		}

		texture.width = width
		texture.height = height
		texture.filter = filter

		meta := default_texture_meta()
		texture.pixels_per_unit = meta.pixels_per_unit
		texture.source_pixels_per_unit = meta.source_pixels_per_unit
		texture.columns = meta.columns
		texture.rows = meta.rows
		texture.frame_count = meta.frame_count
		return
	}

	/*
		Waits for the GPU first, as destroy_mesh does: a texture destroyed the frame after it was
		drawn may still be read
	*/
	destroy_texture :: proc(texture:Texture) {
		if texture.texture == nil do return
		gfx.finish()
		gfx.destroy_texture(texture.texture)
		free(texture.texture)
	}

	/*Clamped edges in every case: repeating would blend in the opposite edge of a sheet's frame*/
	@(private)
	calculate_gxm_filter :: proc(filter:Filter_Mode) -> sce.GxmTextureFilter {
		switch filter {
		case .POINT: return .POINT
		case .LINEAR: return .LINEAR
		}
		return .LINEAR
	}

	/*The image back as plain RGBA rows, top first, which the caller deletes. The padding is left out*/
	@(private)
	read_texture_pixels :: proc(texture:Texture) -> []u8 {
		pixels := make([]u8, texture.width * texture.height * 4)
		for y in 0 ..< int(texture.height) {
			mem.copy(&pixels[y * int(texture.width) * 4], &texture.texture.pixels[y * texture.texture.stride], int(texture.width) * 4)
		}
		return pixels
	}

	/*Reads the .meta next to the image. No file means the defaults and `found` false*/
	@(private)
	load_texture_meta :: proc(filename:string) -> (meta:Texture_Meta, found:bool) {
		path_buffer:[256]u8
		path, path_ok := build_path(path_buffer[:], mbi.asset_path, "images/", strip_extension(filename), ".meta")
		ensure(path_ok, "Image path is too long")

		bytes, read_ok := vito.read_entire_file(path)
		if read_ok == false do return default_texture_meta(), false
		defer delete(bytes)

		error:string
		line:int
		meta, error, line = parse_texture_meta(string(bytes))
		if error != "" {
			print(path, "line", line, ":", error)
			panic("Bad .meta file")
		}
		return meta, true
	}
}
