#+build freestanding arm32

package matchbox

/*
	Skybox (3DS and Vita)
	=====================
	Neither handheld can draw a sky yet, so the names exist and stop with a message. The alternative was to leave them
	out, and a game written for PC then fails to compile on a handheld at a line that says nothing about why. Declared,
	the game builds and the first call says "a skybox is PC only for now". `destroy_skybox` is empty, like every other
	destroy_x a target has nothing to free for, so `destroy` keeps one list of types on every target (destroy.odin)
*/

Backend_Skybox :: struct {}

create_skybox_cubemap :: proc(faces:[6]rawptr, face_size:i32) -> (skybox:Skybox) {
	panic("A skybox is PC only for now")
}

create_skybox_panorama :: proc(pixels:rawptr, width, height:i32) -> (skybox:Skybox) {
	panic("A skybox is PC only for now")
}

load_skybox_cubemap :: proc(filename:string) -> (skybox:Skybox) {
	panic("A skybox is PC only for now")
}

load_skybox_panorama :: proc(filename:string) -> (skybox:Skybox) {
	panic("A skybox is PC only for now")
}

render_skybox :: proc(skybox:Skybox) {
	panic("A skybox is PC only for now")
}

destroy_skybox :: proc(skybox:Skybox) {}
