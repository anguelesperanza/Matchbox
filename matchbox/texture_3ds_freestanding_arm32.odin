#+build freestanding arm32

package matchbox

/*
	Texture -- 3DS
	==============
	Loads the `.t3x` files 3ds_build.bat makes from the game's images (tools/tritex.odin), and
	the `.meta` the build copies next to each one. Same procedures as texture_windows.odin.

	The PICA200 only takes textures whose sides are powers of two from 8 to 1024, stored in
	8 x 8 tiles in Morton order, with the image's top row at v = 1. tritex pads the image into
	the top-left corner of such a canvas, so a texture here has two sizes: `width` / `height`,
	the image's, which everything shared works in, and the canvas's, which only the GPU sees.
	`uv_scale` is the image's share of the canvas, and render_item maps the shared 0..1,
	v-down coordinates onto the canvas with it (calculate_canvas_uv_rectangle).

	Inside `when !VITA` for the reason in backend_3ds_freestanding_arm32.odin
*/

import "core:mem"

import "o3dx/c3d"
import "o3dx/ctru"

when !VITA {

	/*
		The image `filename` names in the assets folder, as the build converted it: assets/images/
		hero.png is romfs:/gfx/hero.t3x, and its .meta, if it has one, is romfs:/gfx/hero.meta.
		Subfolders are kept, as on PC: assets/images/enemies/bat.png is gfx/enemies/bat.t3x
	*/
	load_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		path_buffer:[256]u8
		path, path_ok := get_asset(path_buffer[:], filename, .IMAGE)
		ensure(path_ok, "Image path is too long")

		file := ctru.fopen(path, "rb")
		if file == nil {
			print("No such image:", path)
			panic("Failed to load image")
		}

		texture.texture = new(c3d.C3D_Tex)
		t3x := c3d.Tex3DS_TextureImportStdio(rawptr(file), texture.texture, nil, false)
		ctru.fclose(file)
		if t3x == nil {
			print("Not a .t3x texture:", path)
			panic("Failed to load image")
		}

		// One image per file, as the build makes them. An atlas (several subtextures, from a
		// .t3s) is the old citro2d path, and its rectangles would need a meaning of their own
		ensure(c3d.Tex3DS_GetNumSubTextures(t3x) == 1, "A .t3x for load_texture holds one image")
		image := c3d.Tex3DS_GetSubTexture(t3x, 0)
		texture.width = i32(image.width)
		texture.height = i32(image.height)
		c3d.Tex3DS_TextureFree(t3x)

		set_texture_sampling(&texture, filter)

		meta, meta_found := load_texture_meta(filename)
		texture.pixels_per_unit = meta.pixels_per_unit
		texture.source_pixels_per_unit = meta.source_pixels_per_unit
		texture.columns = meta.columns
		texture.rows = meta.rows
		texture.frame_count = meta.frame_count
		if meta_found == false {
			// The guess reads alpha in plain rows, so the tiled pixels are put back in order
			// first. Only for images with no .meta, and only once, at load
			pixels := read_texture_pixels(texture)
			texture.guessed_meta = calculate_guessed_texture_meta(pixels, texture.width, texture.height)
			delete(pixels)
		}

		ensure(texture.width % texture.columns == 0 && texture.height % texture.rows == 0, "Texture size must divide evenly into its columns and rows")
		return
	}

	/*
		Puts RGBA pixels (8 bits per channel, `width * 4` bytes a row) on the GPU, padded and
		tiled the way tritex does it, so the result reads exactly like a loaded texture.
		The caller owns `pixels` and can free them afterwards
	*/
	create_texture_from_pixels :: proc(pixels:rawptr, width, height:i32, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {
		ensure(width > 0 && height > 0, "A texture needs a size")
		canvas := calculate_texture_canvas_size(width, height)
		ensure(canvas.x <= 1024 && canvas.y <= 1024, "The 3DS takes textures up to 1024 pixels a side")

		texture.texture = new(c3d.C3D_Tex)
		ensure(c3d.C3D_TexInit(texture.texture, u16(canvas.x), u16(canvas.y), .RGBA8), "Out of linear memory for a texture")

		// Zeroed first: the padding is transparent black, as tritex leaves it
		destination := ([^]u8)(c3d.C3D_Tex2DGetImagePtr(texture.texture))
		mem.zero(destination, int(canvas.x * canvas.y * 4))
		source := ([^]u8)(pixels)
		for y in 0 ..< height {
			for x in 0 ..< width {
				from := (y * width + x) * 4
				to := calculate_texel_offset(x, y, canvas.x)
				// RGBA in, ABGR out: the PICA reads RGBA8 texels as one little-endian u32
				destination[to + 0] = source[from + 3]
				destination[to + 1] = source[from + 2]
				destination[to + 2] = source[from + 1]
				destination[to + 3] = source[from + 0]
			}
		}
		c3d.C3D_TexFlush(texture.texture)

		texture.width = width
		texture.height = height
		set_texture_sampling(&texture, filter)

		meta := default_texture_meta()
		texture.pixels_per_unit = meta.pixels_per_unit
		texture.source_pixels_per_unit = meta.source_pixels_per_unit
		texture.columns = meta.columns
		texture.rows = meta.rows
		texture.frame_count = meta.frame_count
		return
	}

	destroy_texture :: proc(texture:Texture) {
		if texture.texture == nil do return
		c3d.C3D_TexDelete(texture.texture)
		free(texture.texture)
	}

	/*
		The canvas tritex puts an image on: each side the next power of two, at least 8. Worked
		out rather than read from the C3D_Tex, which is opaque in o3dx's bindings; both follow
		the same rule, and create_texture_from_pixels makes its own canvas with this
	*/
	@(private)
	calculate_texture_canvas_size :: proc(width, height:i32) -> [2]i32 {
		next :: proc(value:i32) -> i32 {
			size:i32 = 8
			for size < value do size *= 2
			return size
		}
		return {next(width), next(height)}
	}

	/*
		Where image pixel (x, y), y down from the top, sits in the tiled canvas: 8 x 8 tiles
		left to right, the top row of tiles first, and Morton order inside a tile. Byte offset
	*/
	@(private)
	calculate_texel_offset :: proc(x, y, canvas_width:i32) -> i32 {
		tile := (y / 8) * (canvas_width / 8) + x / 8
		inner_x := x & 7
		inner_y := y & 7
		morton := (inner_x & 1) | (inner_y & 1) << 1 | (inner_x & 2) << 1 | (inner_y & 2) << 2 | (inner_x & 4) << 2 | (inner_y & 4) << 3
		return (tile * 64 + morton) * 4
	}

	/*
		Maps a rectangle in the shared texture coordinates (0..1 over the image, v = 0 at its
		top) onto the canvas the GPU samples: scaled by the image's share of the canvas, and
		turned over, because there v = 1 is the top
	*/
	@(private)
	calculate_canvas_uv_rectangle :: proc(texture:Texture, uv:[4]f32) -> [4]f32 {
		canvas := calculate_texture_canvas_size(texture.width, texture.height)
		scale := [2]f32{f32(texture.width) / f32(canvas.x), f32(texture.height) / f32(canvas.y)}
		return {uv[0] * scale.x, 1 - uv[1] * scale.y, uv[2] * scale.x, 1 - uv[3] * scale.y}
	}

	/*
		Filter as asked; edges clamped. Clamping matters for frames at the edge of a sheet:
		repeating would blend in the opposite edge, and on the 3DS the padding beside the image
	*/
	@(private)
	set_texture_sampling :: proc(texture:^Texture, filter:Filter_Mode) {
		texture.filter = filter
		gpu_filter := c3d.GPU_TEXTURE_FILTER_PARAM.NEAREST if filter == .POINT else .LINEAR
		c3d.C3D_TexSetFilter(texture.texture, gpu_filter, gpu_filter)
		c3d.C3D_TexSetWrap(texture.texture, .CLAMP_TO_EDGE, .CLAMP_TO_EDGE)
	}

	/*
		The image back as plain RGBA rows, top first, which the caller deletes. Read from the
		GPU copy, since the file is gone by then; the padding is left out
	*/
	@(private)
	read_texture_pixels :: proc(texture:Texture) -> []u8 {
		canvas := calculate_texture_canvas_size(texture.width, texture.height)
		source := ([^]u8)(c3d.C3D_Tex2DGetImagePtr(texture.texture))
		pixels := make([]u8, texture.width * texture.height * 4)
		for y in 0 ..< texture.height {
			for x in 0 ..< texture.width {
				from := calculate_texel_offset(x, y, canvas.x)
				to := (y * texture.width + x) * 4
				pixels[to + 0] = source[from + 3]
				pixels[to + 1] = source[from + 2]
				pixels[to + 2] = source[from + 1]
				pixels[to + 3] = source[from + 0]
			}
		}
		return pixels
	}

	/*Reads the .meta the build copied next to the .t3x. No file means the defaults and `found` false*/
	@(private)
	load_texture_meta :: proc(filename:string) -> (meta:Texture_Meta, found:bool) {
		path_buffer:[256]u8
		path, path_ok := build_path(path_buffer[:], mbi.asset_path, "gfx/", strip_extension(filename), ".meta")
		ensure(path_ok, "Image path is too long")

		bytes := read_file_bytes(path)
		if bytes == nil do return default_texture_meta(), false
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
