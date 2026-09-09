package matchbox

/*
	Texture_Encoding -- the mapping, and the call sites
	----------------------------------------------------
	Two different claims, checked two different ways.

	**The mapping** (`Texture_Encoding` -> `sdl.GPUTextureFormat`) is ordinary
	logic with no GPU involved, so `test_texture_format_mapping` below calls
	`texture_format` directly, same as any other pure procedure in this
	package.

	**Which encoding each of the seven-plus call sites asks for** is not
	something a test can drive by calling `upload_texture` or
	`create_gpu_texture`: both reach `sdl.CreateGPUTexture` on
	`mbi.renderer.device`, and nothing in `odin test matchbox` stands up a
	real GPU device -- no test file in this package does, and
	`lighting_rework.md` section 8 already rules out GPU capture in this
	environment. Calling them here would be a nil-device crash, not a check.

	What *is* checked is the thing a slipped literal would actually break:
	the source text at each call site. `model_source_asks_for_srgb_base_color`
	and the rest below load the relevant file with `#load` and look for the
	exact call this phase wrote, so a future edit that flips `.SRGB` to
	`.UNORM` (or the reverse) at one of these sites fails a test instead of
	only a code review. This is not a simulation of the hardware decode --
	see `srgb_test.odin` for what was checked about that -- it is a guard on
	the one-line decision this whole file exists to make explicit at each
	site.
*/

import "core:strings"
import "core:testing"

import sdl "vendor:sdl3"

@(test)
test_texture_format_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, texture_format(.UNORM), sdl.GPUTextureFormat.R8G8B8A8_UNORM)
	testing.expect_value(t, texture_format(.SRGB), sdl.GPUTextureFormat.R8G8B8A8_UNORM_SRGB)
}

@(private) MODEL_LOAD_SOURCE  :: #load("model_load.odin", string)
@(private) SKYBOX_SOURCE      :: #load("skybox.odin", string)
@(private) INIT_SOURCE        :: #load("init.odin", string)
@(private) SPRITE_SOURCE      :: #load("sprite.odin", string)
@(private) FONT_SOURCE        :: #load("font.odin", string)
@(private) PIXEL_BUFFER_SOURCE :: #load("pixel_buffer.odin", string)

// glTF base colour -- 3D, colour, sampled by the linear pass. See
// model_load.odin's own comment at the call site.
@(test)
test_model_load_base_color_is_srgb :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(MODEL_LOAD_SOURCE, "upload_texture(pixels, width, height, .SRGB)"),
		"decode_and_upload (model_load.odin) should upload the glTF base colour texture as SRGB")
}

// Panorama and cube map -- both 3D, both colour. Two call sites in one file.
@(test)
test_skybox_textures_are_srgb :: proc(t: ^testing.T) {
	testing.expect(t,
		strings.contains(SKYBOX_SOURCE, "upload_texture(raw_data(image.pixels), image.width, image.height, .SRGB)"),
		"load_skybox_panorama should upload its texture as SRGB")
	testing.expect(t,
		strings.contains(SKYBOX_SOURCE, "create_gpu_texture(i32(face), i32(face), .SRGB, cube = true)"),
		"load_skybox_cubemap should create its texture as SRGB")
}

// The 1x1 white default for an untextured mesh part -- SRGB for consistency
// with the real base-colour textures it stands in for, not because the
// value it holds depends on it. See init.odin's own comment.
@(test)
test_default_white_texture_is_srgb :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(INIT_SOURCE, "upload_texture(&white_pixel, 1, 1, .SRGB)"),
		"init's 1x1 white default texture should upload as SRGB, for consistency with a textured part's own base colour")
}

// Sprites -- 2D, no resolve step downstream. Two call sites (create_mesh and
// create_mesh_from_pixels).
@(test)
test_sprite_textures_are_unorm :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(SPRITE_SOURCE, "upload_texture(pixels, width, height, .UNORM)"),
		"create_mesh should upload a sprite's texture as UNORM -- 2D has no resolve step to re-encode a decoded value")
	testing.expect(t, strings.contains(SPRITE_SOURCE, "upload_texture(raw_data(pixels), width, height, .UNORM)"),
		"create_mesh_from_pixels should upload a sprite's texture as UNORM, for the same reason as create_mesh")
}

// The glyph atlas -- 2D, and coverage rather than colour to begin with.
@(test)
test_font_atlas_is_unorm :: proc(t: ^testing.T) {
	testing.expect(t,
		strings.contains(FONT_SOURCE, "upload_texture(raw_data(rgba), FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .UNORM)"),
		"load_font should upload the glyph atlas as UNORM -- it is a coverage mask, not colour, and is drawn in 2D besides")
}

// Pixel_Buffer -- drawn through the same 2D path a sprite is.
@(test)
test_pixel_buffer_is_unorm :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(PIXEL_BUFFER_SOURCE, "create_gpu_texture(width, height, .UNORM)"),
		"create_pixel_buffer should create its texture as UNORM -- draw_pixel_buffer is a 2D draw with no resolve step")
}
