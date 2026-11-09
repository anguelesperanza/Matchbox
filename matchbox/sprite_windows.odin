#+build windows

package matchbox

/*
	Sprites
	=======
	All sprite data lives here

	A sprite is a full self contained `entity`
*/


import win "core:sys/windows"
import "vendor:directx/d3d11"
import "core:image"
import "core:image/png" // Do not removed -- required for core:image
import "core:strings"

Sprite :: struct {
	source:Rectangle,
	texture:^d3d11.ITexture2D,
	texture_view:^d3d11.IShaderResourceView,
	x:f32,
	y:f32,
	speed:f32,
	width:int,
	height:int,
}

create_sprite :: proc(filename:string) -> (sprite:Sprite) {

	path := filename

	contat_path := strings.concatenate({mbi.asset_path, "images/", path})

	print(contat_path)
	
	img, err := image.load_from_file(contat_path)
	ensure(err == nil, "Failed to load image")


	image.alpha_add_if_missing(img)
	ensure(img.depth == 8 && img.channels == 4, "Image is not RGBA8")

	// img_data := bytes.buffer_to_bytes(&img.pixels)
	img_data := img.pixels[:]

	texture_desc := d3d11.TEXTURE2D_DESC {
		Width = u32(img.width),
		Height = u32(img.height),
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM_SRGB,
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
		SampleDesc = {Count = 1},
	}

	image_bytes_per_row := u32(img.width) * 4

	subresource_data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(img_data),
		SysMemPitch = image_bytes_per_row,
	}


	res := mbi.device->CreateTexture2D(&texture_desc, &subresource_data, &sprite.texture)
	ensure(win.SUCCEEDED(res), "CreateTxture2D Failed")

	res = mbi.device->CreateShaderResourceView(sprite.texture, nil, &sprite.texture_view)
	ensure(win.SUCCEEDED(res), "CreateShaderResourceView Failed")

	sprite.width = img.width
	sprite.height = img.height

	image.destroy(img)

	delete(contat_path)

	sprite.source = {0, 0, cast(f32)sprite.width, cast(f32)sprite.height}

	return
}

destroy_sprite :: proc(sprite:Sprite) {
	if sprite == {} do return
	sprite.texture_view->Release()
	sprite.texture->Release()
}
