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
