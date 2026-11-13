package gfx

// Loading PNG images into textures, using the libpng that comes with VitaSDK
// (its "simplified" API, which takes no floats and needs no bridge).
//
// Link: -lpng16 -lz

import sce "../sce"

foreign import libpng "system:png16"

@(private) PNG_IMAGE_VERSION :: 1
@(private) PNG_FORMAT_RGBA   :: 0x03 // 8 bits each, red first: 0xAABBGGRR as a u32

// png_image from png.h.
@(private) Png_Image :: struct {
    opaque:           rawptr,
    version:          u32,
    width:            u32,
    height:           u32,
    format:           u32,
    flags:            u32,
    colormap_entries: u32,
    warning_or_error: u32,
    message:          [64]u8,
}
#assert(size_of(Png_Image) == 96)

@(default_calling_convention = "c")
foreign libpng {
    @(private) png_image_begin_read_from_memory :: proc(image: ^Png_Image, memory: rawptr, size: uint) -> i32 ---
    @(private) png_image_finish_read            :: proc(image: ^Png_Image, background: rawptr, buffer: rawptr, row_stride: i32, colormap: rawptr) -> i32 ---
    @(private) png_image_free                   :: proc(image: ^Png_Image) ---
}

// libpng's message for the last PNG that failed to load.
last_png_error: [64]u8

// Decodes a PNG held in memory (a file read with vito.read_entire_file, or
// #load) into a new texture. Any PNG type is accepted and converted to 32-bit
// colour with alpha. The largest texture SceGxm takes is 4096 x 4096.
load_png :: proc "contextless" (png: []u8, filter := sce.GxmTextureFilter.LINEAR,
                                address := sce.GxmTextureAddrMode.CLAMP) -> (texture: Texture, ok: bool) {
    image: Png_Image
    image.version = PNG_IMAGE_VERSION
    if png_image_begin_read_from_memory(&image, raw_data(png), uint(len(png))) == 0 {
        last_png_error = image.message
        return {}, false
    }
    image.format = PNG_FORMAT_RGBA

    texture, ok = create_texture(int(image.width), int(image.height), filter, address)
    if !ok {
        png_image_free(&image)
        return {}, false
    }
    // Rows go straight into the texture; its rows may be longer than the image's.
    if png_image_finish_read(&image, nil, texture.pixels, i32(texture.stride * 4), nil) == 0 {
        last_png_error = image.message
        png_image_free(&image)
        destroy_texture(&texture)
        return {}, false
    }
    return texture, true
}
