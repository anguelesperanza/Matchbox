#+build windows

package matchbox

/*
	Texture
	=======
	Creates / Loads images onto the GPU from the assets folder

	uses core:image for image decoding
*/

import win "core:sys/windows"
import "core:image"
import "core:image/png"

import "vendor:directx/d3d11"

Filter_Mode :: enum {
	POINT, // blocky -- like pixel art
	LINEAR, // smooth blending -- like photos and 3D
}

Texture :: struct {
	texture:^d3d11.ITexture2D,
	view:^d3d11.IShaderResourceView,
	filter:Filter_Mode,
	width:i32,
	height:i32,
}

create_texture :: proc(filename:string, filter:Filter_Mode = .LINEAR) -> (texture:Texture) {

	path := get_asset(filename, .IMAGE)
	
	img, err := image.load_from_file(path, options = {.alpha_add_if_missing})
	ensure(err == nil, "Failed to load image") // Might change to a checkered pattern if no image is loaded
	ensure(img.depth == 8 && img.channels == 4, "Texutres must be 8 bits per channel")
	

	desc := d3d11.TEXTURE2D_DESC {
		Width = cast(u32)img.width,
		Height = cast(u32)img.height,
		MipLevels = 1,
		ArraySize = 1,
		Format = .R8G8B8A8_UNORM,
		Usage = .IMMUTABLE,
		BindFlags = {.SHADER_RESOURCE},
		SampleDesc = {Count = 1},
	}

	data := d3d11.SUBRESOURCE_DATA {
		pSysMem = raw_data(img.pixels),
		SysMemPitch = u32(img.width * 4), // bytes in one row
	}

	res := mbi.device->CreateTexture2D(&desc, &data, &texture.texture)
	ensure(win.SUCCEEDED(res), "Create texture failed")

	res = mbi.device->CreateShaderResourceView(texture.texture, nil, &texture.view)
	ensure(win.SUCCEEDED(res), "Create texture view failed")

	texture.filter = filter
	texture.width = i32(img.width)
	texture.height = i32(img.height)		

	image.destroy(img)
	delete(path)

	return
	
}

destroy_texture :: proc(texture:Texture) {
	if texture.view != nil do texture.view->Release()
	if texture.texture != nil do texture.texture->Release()
}
