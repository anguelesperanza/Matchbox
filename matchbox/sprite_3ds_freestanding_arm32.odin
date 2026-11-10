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
import "o3dx/ctru"

/*I should problably move this into the bindings directly in a util file or something*/
// foreign import example_c "system:example_c"

// @(default_calling_convention = "c")
// foreign example_c {
    // load_t3x_image :: proc(path: cstring, tex: ^c3d.C3D_Tex, subtex: ^c2d.Tex3DS_SubTexture) -> bool ---
// }

Sprite :: struct {
	source:Rectangle,
	texture: ^c3d.Tex,
	sub_texture:c2d.Tex3DS_SubTexture,
	image:c2d.Image,
	x:f32,
	y:f32,
	speed:f32,
	width:u16,
	height:u16
}

create_sprite :: proc(filename:string) -> (sprite:Sprite) {


	buf: [256]u8
	path, ok := get_asset(buf[:], filename, .IMAGE)
	ensure(ok && file_exists(path), "Image not found in romfs")

	sprite.texture = cast(^c3d.Tex)ctru.malloc(size_of(c3d.Tex))
	res := c2d.load_t3x_image(path, sprite.texture, &sprite.sub_texture)

	sprite.width = sprite.sub_texture.width
	sprite.height = sprite.sub_texture.height

	sprite.source = {0, 0, cast(f32)sprite.width, cast(f32)sprite.height}

	return sprite
}

destroy_sprite :: proc(sprite:Sprite) {
	sprite := sprite
	c3d.TexDelete(sprite.texture)
	ctru.free(sprite.texture)
}
