package matchbox

/*
	Game shaders
	============
	A shader exists only after the game loads it. The built-in ones (the five that draw every mesh) are always there;
	anything else is a file the game names, so a game that does not want the PSX look carries none of it: no pipeline
	is made and no bytes are in its binary.

		psx := mb.load_shader("psx")          // assets/pc/shaders/psx.pc.hlsl + .pc.refl, from tools/mbsc
		mb.set_shader(psx)                    // everything queued after this is drawn with it
		mb.render_model(model, transform)
		mb.set_shader({})                     // back to the built-in

	**A shader replaces the built-in for the meshes it can draw.** `name` draws plain and lit meshes (a shader that reads the
	normal draws only lit ones, so a sprite or a shape falls back to the built-in), and an optional `name_skinned` beside it
	draws skinned meshes. One `load_shader("psx")` therefore covers the character and the walls without the game saying which
	is which; a skinned mesh with no `_skinned` file is drawn by the built-in.

	**Uniforms** are the ones the shader declares with `@(uniform)`, set by name with `set_shader_value(name, value, shader)`.
	A post-processing shader is a plain shader given to `render_upscaled_target`, which draws the target's picture with it.

	PC only for now: the handhelds take a shader built at build time (S8a/S8b), so there the names stop with a message
	(shader_handheld_freestanding_arm32.odin), as the skybox does
*/

// Zero is the built-in. What it points to differs per target (shader_windows.odin)
Shader :: struct {
	data: rawptr,
}

Shader_State :: struct {
	current: Shader, // set_shader's; every draw queued from now on is stored with it
}

/*The shader everything queued from now on is drawn with, until it is called again. `Shader{}` is the built-in*/
set_shader :: proc(shader: Shader) {
	mbi.shader_state.current = shader
}
