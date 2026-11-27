#+build freestanding arm32

package matchbox

/*
	Game shaders (3DS and Vita)
	===========================
	Neither handheld can load a game's shader yet (it has to be built into a .shbin or .gxp first), so the names exist
	and stop with a message, like the skybox's. `set_shader` is shared and works, since `Shader{}` is the built-in
*/

load_shader :: proc(name: string) -> Shader {
	panic("Custom shaders are PC only for now")
}

load_shader_checked :: proc(name: string) -> (Shader, bool) {
	panic("Custom shaders are PC only for now")
}

set_shader_value :: proc(name: string, value: any, shader := Shader{}) {
	panic("Custom shaders are PC only for now")
}

destroy_shader :: proc(shader: Shader) {}
