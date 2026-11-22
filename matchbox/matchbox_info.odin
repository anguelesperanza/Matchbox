package matchbox

/*
	matchbox_info
	=============

	The global struct that runs Matchbox
	It's shared amongst targets.
	Target specific backend data is stored with	`using backend:Backend_State`

	What each backend defines for the shared files (backend_<target>.odin, unless noted):
	- the types `Backend_State`, `Backend_Texture` and `Mesh`, and the constant `BACKEND_DEFAULTS`
	- `load_texture`, `create_texture_from_pixels`, `destroy_texture`, `get_window_size`,
	  `calculate_mouse_world_position`
	- `camera_start` and `camera_end` (render_<target>.odin)
	- `bake_font_atlas` (font_<target>.odin)
	A target missing one fails its own check script, because a shared file calls it.
*/

Matchbox_Info :: struct {
	is_running:bool,
	did_resize:bool,
	window_size:[4]i32,
	asset_path:string, // shared assets
	target_asset_path:string, // this target's own assets

	// The render queue, filled between camera_start and camera_end (render.odin)
	camera_active:bool,
	screen_pass:bool,
	discard_pass:bool,
	view:matrix[4,4]f32,
	opaque_items:[dynamic]Render_Item,
	transparent_items:[dynamic]Render_Item,
	pixel_scale:f32,
	screen_height:f32,
	bottom_screen_layout:Bottom_Screen_Layout,

	// Meshes every sprite and shape is drawn with, made in `init`
	sprite_mesh:Mesh,
	triangle_mesh:Mesh,
	circle_mesh:Mesh,

	font_settings:Font_Settings,
	screen_settings:Screen_Settings,

	using backend:Backend_State, // so PC code that wrote `mbi.device` still does
}

mbi := Matchbox_Info {
	font_settings = {
		atlas_min_size = 256,
		atlas_max_size = 4096,
		first_glyph = 32,
		line_spacing = 0.15,
	},
	screen_settings = {
		default_height = 12,
		bottom_screen_aspect = 320.0 / 240.0,
	},
	backend = BACKEND_DEFAULTS, // the backend's values, from backend_<target>.odin
}
