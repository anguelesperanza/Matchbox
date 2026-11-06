#+build freestanding arm32

package matchbox

/*
	Sprites
	=======
	All sprite data lives here

	A sprite is a full self contained `entity`
*/

import "o3dx/c3d"
import "o3dx/c2d"

/*I should problably move this into the bindings directly in a util file or something*/
// foreign import example_c "system:example_c"

// @(default_calling_convention = "c")
// foreign example_c {
    // load_t3x_image :: proc(path: cstring, tex: ^c3d.C3D_Tex, subtex: ^c2d.Tex3DS_SubTexture) -> bool ---
// }

Sprite :: struct {
	texture: c3d.Tex,
	sub_texture:c2d.Tex3DS_SubTexture,
	image:c2d.Image,
	x:f32,
	y:f32,
	speed:f32,
	width:u16,
	height:u16
}

create_sprite :: proc(filename:string) -> (sprite:Sprite) {

	// First: Convert png into .t3x file using tools/tritex -- done during built step (compiling .3dsx file)

	// Two: Load in that image using load_t3x_image -- 3DS has no allocator so need to manually do the string contat

	buf:[256]u8
	last_index:int
	gfx:string = "gfx/" // Variable that stors the text "gfx/" -- needed so I can loop through text and pull out characters at index
	ext:string = ".t3x" // Same as above but load_t3x_image takes a .t3x image -- so internally, create_sprite will actually load the .t3x version of the file created during the build step
	for index in 0..< len(mbi.asset_path) {
		buf[index] = mbi.asset_path[index]
		last_index = index
	}


	for index in 0..< len(gfx) {
		last_index += 1
		buf[last_index] = gfx[index]
	}

	for index in 0..< len(filename) {
		last_index += 1
		buf[last_index] = filename[index]

		if filename[index + 1] == 46 do break // stop once we get to the file exention -- need to append .t3x instead 
	}

	for index in 0..< len(ext) {
		last_index += 1
		buf[last_index] = ext[index]
	}

	// concat_string := transmute([256]rune)([256]u8)

	concat_string := cstring(raw_data(buf[:]))

	res := c2d.load_t3x_image(concat_string, &sprite.texture, &sprite.sub_texture)
	ensure(res == true, "Could not load image")

	sprite.width = sprite.sub_texture.width
	sprite.height = sprite.sub_texture.height

	return sprite
}

destroy_sprite :: proc(sprite:Sprite) {
	sprite := sprite
	c3d.TexDelete(&sprite.texture)
}
