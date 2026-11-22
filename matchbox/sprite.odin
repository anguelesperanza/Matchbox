package matchbox

/*
	Sprite
	======
	A textured quad in world space.
	Position is in world units with +Y up
	z is the layer -- Drawn through the same queue as meshes.
*/

import "core:math/linalg"

/*
	How a sprite moves and collides, kept apart from how it looks. Matchbox never
	moves a sprite: the game does, and only the collision procedures (collision.odin)
	read anything here. Embedded in Sprite with `using`, so `sprite.velocity` still
	works and `sprite.body` hands the whole group around
*/
Body :: struct {
	velocity:f32,
	jump_force:f32,
	is_on_ground:bool,

	// Pulls the collision box in from the picture's edges: {left, top, right, bottom},
	// in the image's own pixels so it scales with the sprite. Per side, because art
	// rarely fills its frame evenly -- a character with a hat wants the top pulled in
	// further than the feet. Mirrored with `flip_x`. See calculate_sprite_collision_bounds
	bounding_box_padding:[4]f32,
}

Sprite :: struct {
	using body:Body,
	texture:Texture,
	position:[3]f32,
	rotation:f32, // radians, counter-clockwise about Z
	scale:[2]f32,
	tint:[4]f32,
	pivot:[2]f32, // the point of the image that sits at `position`: {0,0} bottom left, {1,1} top right
	flip_x:bool,
	flip_y:bool,
	pixels_per_unit:f32, // how many image pixels make one world unit
	frame:int, // which frame of the texture to show (see the texture's .meta file). 0 for a plain image
	source:[4]f32, // x, y, width, height in pixels from the image's top left. All zero = use `frame`
}

Sprite_Mode :: enum {
	CUTOUT, // anything under 50% alpha is discarded
	BLENDED, // smooth see-through sorted by z
}

/*`pixels_per_unit` of 0 uses the texture's own (from its .meta file, or 1 without one)*/
create_sprite :: proc(texture:Texture, position:[3]f32 = {}, pixels_per_unit:f32 = 0) -> Sprite {
	return Sprite {
		texture = texture,
		position = position,
		scale = {1, 1},
		tint = {1, 1, 1, 1},
		pivot = {0.5, 0.5},
		pixels_per_unit = pixels_per_unit if pixels_per_unit > 0 else texture.pixels_per_unit,
	}
}

// The part of the image a sprite shows, in pixels {x, y, width, height}: `source` if set, else its frame
@(private)
calculate_sprite_source :: proc(sprite:Sprite) -> [4]f32 {
	if sprite.source[2] > 0 && sprite.source[3] > 0 {
		return sprite.source
	}
	return calculate_texture_frame_rectangle(sprite.texture, sprite.frame)
}

/*The rectangle a sprite covers, in world units: `min` bottom left, `max` top right. Pair it
with `is_point_in_rectangle` to find out whether the mouse is over a sprite.

Rotation is not counted: a rotated sprite gets the rectangle it would have unrotated.
Pixel snapping is not either, so the edges can be up to half a screen pixel off*/
calculate_sprite_bounds :: proc(sprite:Sprite) -> (min, max:[2]f32) {
	source := calculate_sprite_source(sprite)
	size := [2]f32{source[2], source[3]} / sprite.pixels_per_unit * sprite.scale

	min = {sprite.position.x - sprite.pivot.x * size.x, sprite.position.y - sprite.pivot.y * size.y}
	max = min + size
	return
}

/*Queues a sprite to be drawn at camera_end. Sprites are see-through by default*/
render_sprite :: proc(sprite:Sprite, mode:Sprite_Mode = .CUTOUT) {
	ensure(sprite.texture.width > 0, "Sprite has no texture") // not `view`: that is only the PC's
	ensure(sprite.pixels_per_unit > 0, "Sprite pixels_per_unit must be above zero")

	// Which part of the image to show, in pixels
	source := calculate_sprite_source(sprite)

	// As 0..1 texture coordinates. v = 0 is the top of the image
	u0 := source[0] / f32(sprite.texture.width)
	v0 := source[1] / f32(sprite.texture.height)
	u1 := (source[0] + source[2]) / f32(sprite.texture.width)
	v1 := (source[1] + source[3]) / f32(sprite.texture.height)

	// Flipping is just reading the region backwards
	if sprite.flip_x == true do u0, u1 = u1, u0
	if sprite.flip_y == true do v0, v1 = v1, v0

	// World size: pixels -> units, then the user's scale
	size := [2]f32{source[2], source[3]} / sprite.pixels_per_unit * sprite.scale

	// The shared quad is 1x1 and centred on its origin. Shift it so the pivot
	// is at the origin, then scale, rotate and move. Rotation turns about the pivot
	rotation := calculate_rotation_axis_angle({0, 0, 1}, sprite.rotation)
	model := calculate_model_matrix(sprite.position, rotation, {size.x, size.y, 1}) *
		linalg.matrix4_translate_f32({0.5 - sprite.pivot.x, 0.5 - sprite.pivot.y, 0})

	// Pixel snapping: put the four edges on whole screen pixels. Rotated sprites are left as they are
	if mbi.pixel_scale > 0 && sprite.rotation == 0 {
		left := calculate_snapped_to_pixel(sprite.position.x - sprite.pivot.x * size.x, mbi.pixel_scale)
		right := calculate_snapped_to_pixel(sprite.position.x + (1 - sprite.pivot.x) * size.x, mbi.pixel_scale)
		bottom := calculate_snapped_to_pixel(sprite.position.y - sprite.pivot.y * size.y, mbi.pixel_scale)
		top := calculate_snapped_to_pixel(sprite.position.y + (1 - sprite.pivot.y) * size.y, mbi.pixel_scale)

		centre := [3]f32{(left + right) * 0.5, (bottom + top) * 0.5, sprite.position.z}
		model = calculate_model_matrix(centre, linalg.QUATERNIONF32_IDENTITY, {right - left, top - bottom, 1})
	}

	blend := Blend_Mode.NONE
	alpha_cutoff:f32 = 0.5
	if mode == .BLENDED {
		blend = .ALPHA
		alpha_cutoff = 0
	}

	queue_render(mbi.sprite_mesh, model, sprite.tint, blend, .NONE, sprite.texture, {u0, v0, u1, v1}, alpha_cutoff)
}

/*Destroys the sprite -- calls destory_texture under the hood as sprite as the texture*/
destroy_sprite :: proc(sprite:Sprite) {
	destroy_texture(sprite.texture)
}
