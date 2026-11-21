package matchbox

/*
	Shared
	======
	A series of procedures / structs / enums / data shared accross all targets
*/

import "core:math"

Parallax_Direction :: enum {
	LEFT_TO_RIGHT,
	RIGHT_TO_LEFT,
	TOP_TO_BOTTOM,
	BOTTOM_TO_TOP,
}

Parallax_Layer :: struct {
	sprites:   [dynamic]Sprite,
	direction: Parallax_Direction,
	origin:    [2]f32, // where tile 0 sits when offset is 0
	tile_size: [2]f32, // world size of one tile
	offset:    f32,    // how far the strip has scrolled: 0 ..< tile_size along the moving axis
}



/*
	gets the screen bounds of a world
	scale_factor: value used to scale the world (cameara.zoom typically)
		- Default Value: 1 (no scaling happening)
*/
calculate_screen_bounds :: proc(scale_factor:f32 = 1) -> (min, max:[2]f32) {
	size := get_window_size()
	half := [2]f32{f32(size[0]), f32(size[1])} / scale_factor / 2
	return -half, half   // camera at the origin
}

@(private)
parallax_axis_and_sign :: proc(direction:Parallax_Direction) -> (axis:int, sign:f32) {
	switch direction {
	case .LEFT_TO_RIGHT: return 0,  1
	case .RIGHT_TO_LEFT: return 0, -1
	case .BOTTOM_TO_TOP: return 1,  1
	case .TOP_TO_BOTTOM: return 1, -1
	}
	return 0, 1
}

/*
	Loads `filename` and lays copies of it out in a row, ready to scroll
	filename: the image, looked up like load_texture does. Drawn with POINT filtering
	amount: the least number of tiles. More are added until the strip covers the screen plus one spare
		- Default: 1
	direction: which way the tiles travel (used by parallax_move)
		- Default: RIGHT_TO_LEFT
	scale_factor: the camera zoom the layer is made for (the screen size is divided by it)
		- Default: 1 (no scaling)
	layer: the z every tile is drawn at. A bigger z is nearer the camera
		- Default: 0

	All tiles share one texture. Free it and the list with destroy_parallax
*/
create_parallax_layer :: proc(filename:string, amount:i32 = 1, direction:Parallax_Direction = .RIGHT_TO_LEFT, scale_factor:f32 = 1, layer:i32 = 0) -> (parallax:Parallax_Layer) {
	template := create_sprite(load_texture(filename, .POINT))
	screen_min, screen_max := calculate_screen_bounds(scale_factor)

	lo, hi := calculate_sprite_bounds(template)
	parallax.direction = direction
	parallax.tile_size = hi - lo

	axis, _ := parallax_axis_and_sign(direction)

	// Enough tiles to cover the screen plus one spare, whatever `amount` says
	visible := screen_max[axis] - screen_min[axis]
	needed := int(math.ceil(visible / parallax.tile_size[axis])) + 1
	count := max(int(amount), needed)

	// Tile 0's near edge on the screen edge. Uses the sprite's own bounds, so any pivot works
	parallax.origin = {template.position.x, template.position.y}
	parallax.origin[axis] += screen_min[axis] - lo[axis]

	for i in 0..<count {
		tile := template
		tile.position = {parallax.origin.x, parallax.origin.y, f32(layer)}
		tile.position[axis] += f32(i) * parallax.tile_size[axis]
		append(&parallax.sprites, tile)
	}
	return
}

/*
	Scrolls the layer. Every tile is placed from one shared offset, so they stay exactly one
	tile apart however long it runs
	parallax: the layer from create_parallax_layer
	delta_time: delta time
	speed: world units per second
		- Default: 10
*/
parallax_move :: proc(parallax:^Parallax_Layer, delta_time:f32, speed:f32 = 10) {
	if len(parallax.sprites) == 0 do return

	axis, sign := parallax_axis_and_sign(parallax.direction)
	size := parallax.tile_size[axis]

	// The strip repeats every tile, so wrapping the offset is the whole wrap logic
	parallax.offset = math.mod(parallax.offset - sign * speed * delta_time, size)
	if parallax.offset < 0 do parallax.offset += size

	for &tile, i in parallax.sprites {
		tile.position[axis] = parallax.origin[axis] + f32(i) * size - parallax.offset
	}
}

/*Renders the parallax sprites*/
render_parallax :: proc(parallax:Parallax_Layer) {
	for sprite in parallax.sprites {
		render_sprite(sprite)
	}
}

/*
	Frees up the resources used by the parallax
	All the sprites share one texture, so it is destroyed once
*/
destroy_parallax :: proc(parallax:Parallax_Layer) {
	if len(parallax.sprites) > 0 {
		destroy_sprite(parallax.sprites[0])
	}
	delete(parallax.sprites)
}
