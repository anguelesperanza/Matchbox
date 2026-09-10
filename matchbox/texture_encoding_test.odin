package matchbox

/*
	Texture_Encoding -- the mapping
	---------------------------------
	`Texture_Encoding` -> `sdl.GPUTextureFormat` is ordinary logic with no GPU
	involved, so it is called directly here the same as any other pure
	procedure in this package.

	**Which encoding each call site asks for is deliberately not tested, and
	that is worth explaining rather than leaving as an omission.** It cannot
	be driven behaviourally: `upload_texture` and `create_gpu_texture` both
	reach `sdl.CreateGPUTexture` on `mbi.renderer.device`, and nothing in
	`odin test matchbox` stands up a real device -- no test file in this
	package ever has.

	The first version of this file reached for the next best thing and
	asserted on the *source text*, `#load`-ing `model_load.odin`,
	`skybox.odin`, `sprite.odin` and the rest and looking for the exact call
	each one had been written with. That was removed, because it fails in the
	wrong direction: renaming a local variable at one of those call sites --
	a change that alters nothing about the encoding -- breaks a test whose
	message says the encoding is wrong. A test that reports the wrong cause
	is worse than no test, because the next person spends their time on the
	message rather than on the diff. It also embedded six source files into
	the test binary as string constants to check a decision that is one
	clearly-commented argument at each site.

	What guards those call sites instead is `Texture_Encoding`'s own doc
	comment (upload.odin), which states the rule the choice follows -- not
	"is this data colour" but "does something downstream re-encode it exactly
	once" -- and the fact that `encoding` has no default, so a new call site
	cannot inherit an answer without stating one.
*/

import "core:testing"

import sdl "vendor:sdl3"

@(test)
test_texture_format_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, texture_format(.UNORM), sdl.GPUTextureFormat.R8G8B8A8_UNORM)
	testing.expect_value(t, texture_format(.SRGB),  sdl.GPUTextureFormat.R8G8B8A8_UNORM_SRGB)
}
