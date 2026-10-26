package matchbox

/*
	Sprites
	=======
	All sprite data lives here

	A sprite is a full self contained `entity`
*/

Sprite :: struct {
	x:f64,
	y:f64,
	speed:f64,
}

create_sprite :: proc(filepath:string) -> (sprite:Sprite) {
	
	return
}

destroy_sprite :: proc(sprite:Sprite) {
	
}
