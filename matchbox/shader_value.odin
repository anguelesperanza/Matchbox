package matchbox

/*
	The one rule for turning what a game passes to `set_shader_value` into a number, shared by the 3DS (shader_pica.odin)
	and the Vita (shader_vita.odin) so the two cannot drift apart.
*/

// A literal like 0.5 or 3 arrives as an f64 or an int; the shader's f32 decides what it means
value_as_f32 :: proc(value: any) -> (number: f32, ok: bool) {
	switch v in value {
	case f32: return v, true
	case f64: return f32(v), true
	case int: return f32(v), true
	}
	return 0, false
}
