package matchbox

/*
	Texture
	=======
	What a texture is on every target. The GPU objects differ per console and live in
	`Backend_Texture` (backend_<target>.odin), embedded with `using`; loading and
	destroying are each backend's (texture_<target>.odin).
*/

Filter_Mode :: enum {
	POINT, // blocky -- like pixel art
	LINEAR, // smooth blending -- like photos and 3D
}

Texture :: struct {
	using backend:Backend_Texture, // the GPU objects, which differ per target
	filter:Filter_Mode,
	width:i32,
	height:i32,

	// From the optional .meta file next to the image (see texture_meta.odin)
	pixels_per_unit:f32, // image pixels per world unit. Sprites use it as their default
	source_pixels_per_unit:f32, // the full-size sheet's ppu when this is a target's smaller copy, else 0 (texture_meta.odin)
	columns:i32, // frames across
	rows:i32, // frames down
	frame_count:i32,

	// For an image with no .meta file: a best guess at its frames, worked out from
	// its pixels when it is loaded, since they are gone from the CPU after that.
	// create_animation_clip uses it; plain drawing never does (see
	// calculate_guessed_texture_meta). All zero when there was a .meta file.
	guessed_meta:Texture_Meta,
}

/*The pixel rectangle {x, y, width, height} of one frame. Frame 0 is the top left,
then left to right, then down*/
calculate_texture_frame_rectangle :: proc(texture:Texture, frame:int) -> [4]f32 {
	ensure(frame >= 0 && frame < int(texture.frame_count), "Texture frame is out of range")

	frame_width := texture.width / texture.columns
	frame_height := texture.height / texture.rows
	column := i32(frame) % texture.columns
	row := i32(frame) / texture.columns

	return {f32(column * frame_width), f32(row * frame_height), f32(frame_width), f32(frame_height)}
}
