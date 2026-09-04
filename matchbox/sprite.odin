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

// A sprite from an encoded image -- PNG, JPG, whatever stb_image reads.
// `#load` the file and hand the bytes over, so the image ships inside the
// executable and works the same inside an Android apk.
create_sprite :: proc(bytes: []byte, scale: f32 = 1) -> Sprite {
	mesh := create_mesh(bytes)
	return create_sprite_from_mesh(mesh, scale)
}

/*A sprite around pixels the game already holds. See create_mesh_from_pixels*/
create_sprite_from_pixels :: proc(pixels: []byte, width, height: i32, scale: f32 = 1) -> Sprite {
	mesh := create_mesh_from_pixels(pixels, width, height)
	return create_sprite_from_mesh(mesh, scale)
}

/*The body every sprite gets, whichever way its texture arrived*/
@(private)
create_sprite_from_mesh :: proc(mesh: Mesh, scale: f32) -> Sprite {
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

// Gives the sprite's texture and vertex buffer back to the GPU. A sprite whose
// mesh came from `sprite_cache` must not be destroyed here -- the cache owns it
// and hands the same one to everybody who asked for that image.
destroy_sprite :: proc(sprite: ^Sprite) {
	destroy_mesh(&sprite.mesh)
}

// The middle of the sprite in world coordinates.
//
// Off `position` and `size` rather than off `pivot`: this is where the sprite
// visually is, which is what a distance check or a camera follow wants, and not
// where it is anchored for drawing.
sprite_center :: proc(sprite: Sprite) -> [2]f32 {
	return {
		sprite.position.x + sprite.size.x / 2,
		sprite.position.y + sprite.size.y / 2,
	}
}

// -----------------------------------------------------------------------
// Parallax
// -----------------------------------------------------------------------

/*
	Layers that move with the camera at different rates, which is what reads as
	depth in a 2D scene.

	`parallax_speed` is **the fraction of the camera's movement a layer
	follows**: 1 moves with the world exactly as an ordinary sprite does, 0.5
	drifts at half the rate and so looks further away, and 0 is pinned to the
	screen -- an infinitely distant backdrop.

		sky := mb.create_parallax()
		mb.parallax_add(&sky, backdrop, 0)     // never moves
		mb.parallax_add(&sky, hills,    0.3)
		mb.parallax_add(&sky, trees,    0.7)

		mb.begin_drawing_2d()
		mb.draw_parallax(sky)                  // back to front, before the world
		mb.draw_sprite(player)
		mb.end_drawing_2d()

	**This only means anything inside `begin_drawing_2d`/`end_drawing_2d`**,
	because the effect is defined against the camera offset that `screen_pos`
	applies. Drawn outside one, every layer falls back to its own position and
	the set is just a list of sprites -- which is the honest answer, since with
	no camera there is no movement to be a fraction of.

	**On the direction of the number.** It reads the way it does everywhere else
	-- a bigger `parallax_speed` moves more -- and the alternative was to make it
	a depth, where 0 meant the world plane and 1 meant pinned. That version has
	the tidier zero value, matching how `Body.tint` and `scale` treat theirs as
	"behave normally". It was rejected because it would invert the meaning of a
	universally understood name: `parallax_speed = 1` would have meant *does not
	move*, and every person who had met parallax anywhere else would have had it
	backwards. The field's raw zero therefore means pinned, which only comes up
	if a set is assembled by hand rather than through `parallax_add`.
*/
create_parallax :: proc(allocator := context.allocator) -> Parallax_Sprites {
	return Parallax_Sprites{sprites = make([dynamic]Sprite, allocator)}
}

/*
	Adds a layer, drawn in front of everything already in the set.

	`speed` is written onto the sprite, so it is the one place a layer's depth
	is stated and the sprite does not have to be built with it. It defaults to
	1 -- moving with the world -- rather than to the field's own zero, because
	a layer added without a stated depth should behave like an ordinary sprite
	rather than silently pinning itself to the screen. Say `0` when that is
	what is wanted; it is the more striking effect and worth being explicit
	about.
*/
parallax_add :: proc(set: ^Parallax_Sprites, sprite: Sprite, speed: f32 = 1) {
	layer := sprite
	layer.parallax_speed = speed
	append(&set.sprites, layer)
}

/*
	Draws every layer, first to last, so the set is ordered back to front.

	There is no `update_parallax` to pair with this, and that is deliberate. The
	offset is a pure function of where the camera is right now, so working it
	out at draw time means a layer cannot drift out of step with the camera,
	drawing twice gives the same picture twice, and a skipped or doubled frame
	changes nothing. The alternative -- advancing each layer's `position` by the
	camera's movement every frame -- accumulates floating-point error, needs the
	previous camera position kept somewhere, and quietly desynchronises if
	anything ever calls it other than exactly once per frame.

	A layer's own `position` therefore keeps meaning what it says: where that
	layer sits in the world, not where it happens to have scrolled to.
*/
draw_parallax :: proc(set: Parallax_Sprites) {
	for layer in set.sprites {
		drawn := layer
		drawn.position = parallax_position(layer)
		draw_sprite(drawn)
	}
}

/*
	Where a layer is drawn, given where the camera is.

	`screen_pos` subtracts the camera position from everything drawn through it,
	so placing a layer at `base + camera * (1 - speed)` lands it at
	`base - camera * speed` on screen -- moving at exactly `speed` of the
	camera's movement, which is the whole definition. At `speed` 1 the two
	cancel and the layer is an ordinary world-space sprite; at 0 the offset
	cancels the camera entirely and the layer holds still.
*/
@(private)
parallax_position :: proc(sprite: Sprite) -> [2]f32 {
	if !mbi.camera.active do return sprite.position
	return sprite.position + mbi.camera.position * (1 - sprite.parallax_speed)
}

// Destroys every layer of a parallax set, and the set's own storage. The layers
// own their meshes, unlike cache-backed sprites, so this is the right way to
// take one down.
destroy_parallax :: proc(parallax_sprites: ^Parallax_Sprites) {
	for &i in parallax_sprites.sprites {
		destroy_sprite(&i)
	}

	delete(parallax_sprites.sprites)
	parallax_sprites.sprites = nil
}

/*
	Draws a sprite at its position, turned about its pivot and multiplied by its
	tint.

	The pivot is measured the opposite way round from most engines: `{0, 0}`
	means `position` already is the centre, and `{0.5, 0.5}` offsets the sprite
	by half its own size. Worth knowing before a crosshair comes out as a
	corner.
*/
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

	vert_data := Vert_Data{
		position = screen_pos(draw_center),
		size     = screen_size(sprite.size),
		screen   = get_screen_dims(),
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

// The body's collision rectangle as {left, top, right, bottom}, with its
// per-side padding applied.
//
// Padding is per-side rather than one number because a sprite's art rarely
// fills its own box evenly -- a character with a hat wants the top pulled in
// further than the feet.
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
	vert_data := Vert_Data{
		position = screen_pos(center),
		size     = screen_size(size),
		screen   = get_screen_dims(),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rotation,
	}

	frag_data := Outline_Frag_Data{
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


/*
	The sprite's position clamped so it cannot leave the visible area.

	Returns the corrected position rather than writing it, so a caller decides
	whether hitting the edge also means stopping, bouncing or wrapping.

	The edges are worked out in world coordinates by undoing the letterbox: the
	visible area is not the window when `set_logical_size` is in force, and
	using the window size here would let a sprite sit in the black bars.
*/
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

// Whether two {left, top, right, bottom} rectangles overlap.
//
// Strictly, so two boxes sharing an edge do not count as overlapping. That is
// what stops a character resting exactly on a platform from being reported as
// inside it every frame -- see `is_bounding_box_contact` for the opposite.
is_bounding_box_collision :: proc(a: [4]f32, b: [4]f32) -> bool {
	return a[0] < b[2] &&
	       a[2] > b[0] &&
	       a[1] < b[3] &&
	       a[3] > b[1]
}
// The same test as `is_bounding_box_collision`, except that touching counts.
//
// One `>=` is the whole difference, on the bottom edge: a character standing on
// a platform is exactly in contact with it and not overlapping it, so an
// overlap test reports "not standing on anything" on the very frame it lands.
is_bounding_box_contact :: proc(a: [4]f32, b: [4]f32) -> bool {
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

// Which side of the sprite image is its forward-facing direction at rotation 0.
Sprite_Forward :: enum {
    TOP,    // top of the image faces the target  (default — suits top-down sprites)
    RIGHT,  // right side of the image faces the target
    BOTTOM, // bottom of the image faces the target
    LEFT,   // left side of the image faces the target
}

// Returns the angle (radians) needed to face a sprite's visual center toward target.
// Uses position + pivot * size so rotation is always computed from the correct origin.
// forward controls which side of the sprite is treated as its forward direction.
//
// The inverse of `sprite_forward_by_rotation` above: that one reads a sprite's
// rotation and gives the direction it faces, this one takes a direction and
// gives the rotation that would face it.
look_at_sprite :: proc(sprite: Sprite, target: [2]f32, forward: Sprite_Forward = .TOP) -> f32 {
	center := sprite.position + sprite.pivot * sprite.size
	return look_at_point(center, target, forward)
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
