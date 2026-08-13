package matchbox

/*
	Collisions: This file handles collision detection related information
	---------------------------------------------------------------------
	Handles collsions and logic related to collisions
*/


/*
	Converts a sprites x and y into a 1D array index
	This is row-major so all the rows are stored consecutively
*/
sprite_to_index_by_sprite :: proc(player:Sprite) -> (index:int) {
	index = int(player.position.y * player.size.x + player.position.x)
	return
}
sprite_to_index_by_value :: proc(x:f32, y:f32, width:f32) -> (index:int) {
	index = int(y * width + x)
	return
}

/*
	Whether the pointer is over a sprite.

	Through point_in_rect, which means the sprite's `pivot` is now accounted
	for. This used to test position..position + size directly, which is only
	right when the pivot is {0.5, 0.5} -- what create_sprite gives you, so the
	usual case was fine and a sprite with any other pivot had its hitbox half a
	size away from the picture.
*/
mouse_over_sprite :: proc(sprite:Sprite) -> bool {
	return point_in_rect(get_mouse_position(), {
		position = sprite.position,
		size     = sprite.size,
		pivot    = sprite.pivot,
	})
}

