package matchbox

import "core:math"

import stbi "vendor:stb/image"
import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Sprites
// -----------------------------------------------------------------------

Sprite :: struct {
	using mesh: Mesh,
	using body: Body,
	parallax_speed: f32,
}

// Decoding is what loading an image costs -- the upload to the gpu underneath
// is nothing next to it -- so this goes through stb rather than core:image,
// which is roughly five times slower on the same file. stb is already linked
// for the font atlas, so it is not a new dependency.
create_mesh :: proc(bytes: []byte) -> Mesh {
	width, height, channels_in_file: i32

	// 4 forces RGBA out of whatever the file holds, which is what the texture
	// format below wants and what alpha_add_if_missing used to guarantee
	pixels := stbi.load_from_memory(raw_data(bytes), cast(i32)len(bytes), &width, &height, &channels_in_file, 4)
	ensure(pixels != nil, "Could not load texture")
	defer stbi.image_free(pixels)

	// The quad every sprite draws with is shared and already on the GPU, so all
	// that is uploaded here is the texture.
	return Mesh{
		texture = upload_texture(pixels, width, height),
		sampler = mbi.renderer.sprite_sampler,
		width   = width,
		height  = height,
	}
}

/*
	The same, from pixels that have already been decoded.

	create_mesh takes an encoded image because that is what a sprite loaded off
	disk is. A game that has *made* an image -- composited one, rendered one,
	read one out of a buffer -- would otherwise have to encode it to a PNG so
	that stb could decode it straight back again.

	`pixels` is RGBA8, `width * height * 4` bytes, and is copied on the way to
	the GPU: it belongs to the caller both before and after.
*/
create_mesh_from_pixels :: proc(pixels: []byte, width, height: i32) -> Mesh {
	ensure(width > 0 && height > 0, "a texture needs a size")
	ensure(len(pixels) >= int(width) * int(height) * 4, "not enough pixels for that size")

	return Mesh{
		texture = upload_texture(raw_data(pixels), width, height),
		sampler = mbi.renderer.sprite_sampler,
		width   = width,
		height  = height,
	}
}

create_sprite :: proc(bytes: []byte, scale: f32 = 1) -> Sprite {
	mesh := create_mesh(bytes)
	return sprite_of(mesh, scale)
}

/*A sprite around pixels the game already holds. See create_mesh_from_pixels*/
create_sprite_from_pixels :: proc(pixels: []byte, width, height: i32, scale: f32 = 1) -> Sprite {
	mesh := create_mesh_from_pixels(pixels, width, height)
	return sprite_of(mesh, scale)
}

/*The body every sprite gets, whichever way its texture arrived*/
@(private)
sprite_of :: proc(mesh: Mesh, scale: f32) -> Sprite {
	final_scale := scale
	if scale <= 0 {
		final_scale = 1
	}

	width  := cast(f32)mesh.width  * final_scale
	height := cast(f32)mesh.height * final_scale

	return Sprite{
		mesh = mesh,
		body = Body{
			position = {0, 0},
			size     = {width, height},
			scale    = final_scale,
			pivot    = {0.5, 0.5},
			uv_min   = {0, 0},
			uv_max   = {1, 1},
			tint     = WHITE,
		},
	}
}

// Only the texture is owned. The sampler is shared with every other sprite and
// outlives them, and the quad belongs to the renderer.
destroy_mesh :: proc(mesh: ^Mesh) {
	if mesh.texture != nil && mbi.renderer.device != nil {
		sdl.ReleaseGPUTexture(mbi.renderer.device, mesh.texture)
	}
	mesh.texture = nil
}

destroy_sprite :: proc(sprite: ^Sprite) {
	destroy_mesh(&sprite.mesh)
}

sprite_center :: proc(sprite: Sprite) -> [2]f32 {
	return {
		sprite.position.x + sprite.size.x / 2,
		sprite.position.y + sprite.size.y / 2,
	}
}

destroy_parallax :: proc(parallax_sprites: ^ParallaxSprites) {
	for &i in parallax_sprites.sprites {
		destroy_sprite(&i)
	}
}

draw_sprite :: proc(sprite: Sprite) {
	draw_center := sprite.position + sprite.pivot * sprite.size

	// Flipping is a swap of the uv bounds, not `1 - uv` in the shader. The
	// shader only ever sees uv already narrowed to the sprite's sub-rect, so
	// reflecting there reflects around the middle of the whole texture and
	// lands in a different frame -- on a four column sheet, frame 1 runs
	// 0.25..0.5 and a pixel at 0.30 came out at 0.70, which is frame 2.
	//
	// Swapping the bounds is right whatever the sub-rect is, and is what
	// update_animation was already doing to sidestep the same problem.
	uv_min := sprite.uv_min
	uv_max := sprite.uv_max
	if sprite.flip_x do uv_min.x, uv_max.x = uv_max.x, uv_min.x
	if sprite.flip_y do uv_min.y, uv_max.y = uv_max.y, uv_min.y

	vert_data := VertData{
		position = screen_pos(draw_center),
		size     = screen_size(sprite.size),
		screen   = screen_dims(),
		rotation = sprite.rotation,
		uv_min   = uv_min,
		uv_max   = uv_max,
	}

	frag_data := sprite_frag_data(sprite.body)

	draw_quad(
		mbi.renderer.pipelines.sprite, &vert_data, &frag_data, size_of(frag_data),
		sprite.texture, sprite.sampler,
	)
}

/*
	The tint a body draws with.

	An all-zero tint is read as "as it was painted" rather than "multiply by
	transparent black". A Body that nobody has filled in has to draw the picture
	-- every sprite predating the tint has a zero there, and the alternative is
	that all of them silently stop appearing.

	The two readings do not otherwise collide. Fading a sprite out is
	{1, 1, 1, a}, which stays non-zero all the way down to a = 0, and multiplying
	by transparent black is only ever a long way of drawing nothing.
*/
@(private)
sprite_frag_data :: proc(body: Body) -> Sprite_Frag_Data {
	tint := body.tint
	if tint == {0, 0, 0, 0} do tint = WHITE

	return Sprite_Frag_Data{color = tint, desaturate = clamp(body.desaturate, 0, 1)}
}

sprite_bounds :: proc(body: ^Body) -> [4]f32 {
	p := body.bounding_box_padding
	return {
		body.position.x + p[0],
		body.position.y + p[1],
		body.position.x + body.size.x - p[2],
		body.position.y + body.size.y - p[3],
	}
}

/*
	A hollow rectangle, `thickness` pixels thick on every side.

	`thickness` used to be a fraction the shader compared against uv on both
	axes, which made the thickness that came out `thickness * size` per axis:
	one number on a square, two on anything else, with the long side getting
	the heavy one. A 460x52 text box with 0.04 drew eighteen pixels down the
	sides against two along the top, and swallowed the first characters typed
	into it.

	It reads like a width, so now it is one. The conversion to the shader's
	per-axis half-extent happens here, where the size is known.

	Note the units changed with the meaning: a call that used to pass 0.04
	wants roughly 2 for the same look on a short box, not 0.04, which is now a
	line too thin to see. draw_outline_proportional is the old behaviour under
	a name that says so.
*/
draw_outline :: proc(center: [2]f32, size: [2]f32, color: [4]f32, thickness: f32, rotation: f32) {
	// Guarded because a zero-sized rectangle would divide by zero, and because
	// past half the extent the two edges cross and the frame fills solid.
	border := [2]f32{0, 0}
	if size.x > 0 do border.x = clamp(thickness / size.x, 0, 0.5)
	if size.y > 0 do border.y = clamp(thickness / size.y, 0, 0.5)

	draw_outline_uv(center, size, color, border, rotation)
}

/*
	A hollow rectangle whose border keeps its proportions as the shape changes.

	This is what draw_outline did before it took a thickness, kept because it
	is the right thing for an outline that should scale with what it surrounds
	-- a card-shaped zone whose frame stays in proportion as the board zooms.
	`fraction` is a share of each side, so 0.02 is two percent of the width
	across the vertical edges and two percent of the height across the
	horizontal ones.
*/
draw_outline_proportional :: proc(center: [2]f32, size: [2]f32, color: [4]f32, fraction: f32, rotation: f32) {
	f := clamp(fraction, 0, 0.5)
	draw_outline_uv(center, size, color, {f, f}, rotation)
}

@(private)
draw_outline_uv :: proc(center: [2]f32, size: [2]f32, color: [4]f32, border: [2]f32, rotation: f32) {
	vert_data := VertData{
		position = screen_pos(center),
		size     = screen_size(size),
		screen   = screen_dims(),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rotation,
	}

	frag_data := OutlineFragData{
		color  = color,
		border = border,
	}

	draw_quad(mbi.renderer.pipelines.outline, &vert_data, &frag_data, size_of(frag_data))
}

// `thickness` is in pixels, the same on every side. See draw_outline for what
// that used to mean and why it changed.
draw_bounding_box_outline :: proc(body: ^Body, color: [4]f32, thickness: f32) {
	bb     := sprite_bounds(body)
	center := [2]f32{(bb[0] + bb[2]) * 0.5, (bb[1] + bb[3]) * 0.5}
	size   := [2]f32{bb[2] - bb[0], bb[3] - bb[1]}

	draw_outline(center, size, color, thickness, body.rotation)
}

// `thickness` is in pixels, the same on every side. See draw_outline for what
// that used to mean and why it changed.
draw_rect_outline :: proc(body: ^Body, color: [4]f32, thickness: f32) {
	center := body.position + body.pivot * body.size
	draw_outline(center, body.size, color, thickness, body.rotation)
}


sprite_world_collision :: proc(sprite: Sprite) -> [2]f32 {
	pos   := sprite.position
	scale := f32(1)
	if mbi.draw_scale > 0 {
		scale = mbi.draw_scale
	}
	left   := -mbi.draw_offset[0] / scale
	right  := (cast(f32)mbi.window_width  - mbi.draw_offset[0]) / scale
	top    := -mbi.draw_offset[1] / scale
	bottom := (cast(f32)mbi.window_height - mbi.draw_offset[1]) / scale
	pos.x   = clamp(pos.x, left, right  - sprite.size[0])
	pos.y   = clamp(pos.y, top,  bottom - sprite.size[1])
	return pos
}

bounding_box_collision_check :: proc(a: [4]f32, b: [4]f32) -> bool {
	return a[0] < b[2] &&
	       a[2] > b[0] &&
	       a[1] < b[3] &&
	       a[3] > b[1]
}
bounding_box_contact_check :: proc(a: [4]f32, b: [4]f32) -> bool {
    return a[0] < b[2] &&
           a[2] > b[0] &&
           a[1] < b[3] &&
           a[3] >= b[1]
}
// Returns the forward direction vector of a sprite based on its current rotation.
// Useful for movement in the direction a sprite is facing (e.g. tanks).
sprite_forward_by_rotation :: proc(sprite: Sprite) -> [2]f32 {
	s, c := math.sincos(sprite.rotation)
	return [2]f32{s, -c}
}


// Selects a single tile from a sprite sheet by its column and row (0-indexed).
// Also corrects sprite.size to one tile so the bounding box is right.
//
// spacing: gap in pixels between adjacent tiles (e.g. 1 for a 1px grid line).
// margin:  gap in pixels before the first tile (top-left border of the sheet).
//
// UVs are computed in pixel space from the sprite's own texture dimensions so
// only the tile is sampled -- the spacing/margin is never included, which would
// otherwise bleed the neighbouring gap into the tile's edges.
sprite_set_frame :: proc(sprite: ^Sprite, col, row: int, tile_w, tile_h: f32, spacing: f32 = 0, margin: f32 = 0) {
    tex_w := f32(sprite.width)
    tex_h := f32(sprite.height)

    px := margin + f32(col) * (tile_w + spacing)
    py := margin + f32(row) * (tile_h + spacing)

    sprite.size   = {tile_w * sprite.scale, tile_h * sprite.scale}
    sprite.uv_min = {px            / tex_w, py            / tex_h}
    sprite.uv_max = {(px + tile_w) / tex_w, (py + tile_h) / tex_h}
}
