package matchbox

/*
	Shared
	======
	A series of procedures / structs / enums / data shared accross all targets
*/

Parallax_Direction :: enum {
	LEFT_TO_RIGHT,
	RIGHT_TO_LEFT,
	TOP_TO_BUTTOM,
	BOTTOM_TO_TOP,
}

/*
	gets the screen bounds of a world
	scale_factor: value used to scale the world (cameara.zoom typically)
		- Default Value: 1 (no scaling happening)
*/
get_screen_bounds :: proc(scale_factor:f32 = 1) -> (min, max:[2]f32) {
	size := get_window_size()
	half := [2]f32{f32(size[0]), f32(size[1])} / scale_factor / 2
	return -half, half   // camera at the origin
}

/*
	Sets up the positions of the parallax for the sprites
	sprite: The sprite to use for the parallax effect
	amount: The number of duplicates of the sprites that the parallax will have
	direction: controls which way the parallax moves
		- Default: LEFT_TO_RIGHT
	scale_factor: the value used to scale the sprites
		- Default: 1 (no scalling, use native image size)
	layer: How far on the z axis the sprite is rendered
		- Default: 1

	Parallax is an array of the exact same sprite. They all move at the same time, at the same speed, but are positions one after the other.
*/
create_parallax_sprites :: proc(filename:string, amount:int = 3, scale_factor:f32 = 1, layer:f32 = 0) -> (parallax:[dynamic]Sprite) {

	// parallax[0] = create_sprite(create_texture(filename))

	append(&parallax, create_sprite(create_texture(filename)))
	
	min, _ := get_screen_bounds(scale_factor)

	lo, hi := get_sprite_bounds(parallax[0])
	width := hi.x - lo.x

	for i in 0..<amount {
		tile := parallax[0]
		// first tile's left edge on the screen's left edge, then one width further each
		tile.position = {min.x + width / 2 + f32(i) * width, parallax[0].position.y, layer}
		append(&parallax, tile)
	}
	return
}

/*
	Moves the parallax based on direction and moves them to create a seamless transition
	parallax: slice made from a parallax (parallax[:])
	speed = How fast the parallax scrolls
		- Default: 10
	dt = delta time
	scale_factor: what the sprites are scaled at
		- Default: 1 (no scaling)
*/
parallax_move :: proc(parallax:[]Sprite, dt:f32, speed:f32 = 10, scale_factor:f32 = 1, direction:Parallax_Direction = .RIGHT_TO_LEFT) {
	if len(parallax) == 0 do return

	min, max := get_screen_bounds(scale_factor)
	lo, hi := get_sprite_bounds(parallax[0])
	strip := (hi - lo) * f32(len(parallax))   // whole strip, per axis

	for &bg in parallax {
		switch direction {
		case .LEFT_TO_RIGHT:
			bg.position.x += speed * dt
			tile_lo, _ := get_sprite_bounds(bg)
			if tile_lo.x > max.x do bg.position.x -= strip.x
		case .RIGHT_TO_LEFT:
			bg.position.x -= speed * dt
			_, tile_hi := get_sprite_bounds(bg)
			if tile_hi.x < min.x do bg.position.x += strip.x
		case .BOTTOM_TO_TOP:
			bg.position.y += speed * dt
			tile_lo, _ := get_sprite_bounds(bg)
			if tile_lo.y > max.y do bg.position.y -= strip.y
		case .TOP_TO_BUTTOM:
			bg.position.y -= speed * dt
			_, tile_hi := get_sprite_bounds(bg)
			if tile_hi.y < min.y do bg.position.y += strip.y
		}
	}
}

/*Renders the parallax sprites*/
render_parallax :: proc(parallax:[]Sprite) {
	for sprite in parallax {
		render_sprite(sprite)
	}
}


/*
	Frees up the resources used by the parallax sprites
	All sprites in parallax reference the first one (parallax[0])
	so only the first sprite is freed
*/
destroy_parallax :: proc(parallax:[]Sprite) {
	destroy_sprite(parallax[0])
}
