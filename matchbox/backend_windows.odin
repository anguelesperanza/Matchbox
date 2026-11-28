#+build windows

package matchbox

/*
	Backend (PC)
	============
	This is the PC specific backend implementation.

	This has win32, GameInput, D3D11
	What only the PC has: the window, Win32 input and GameInput, D3D11.
*/

import win "core:sys/windows"

import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import gi "vendor:windows/GameInput"

// Bytes of typed text kept per frame: a fixed array bound, so a constant. A person types a few characters a frame; a paste would not come through WM_CHAR
MAX_TEXT_INPUT :: 256

Backend_State :: struct {
	// Win32
	window:win.HWND,
	event_message:^win.MSG,

	keys_pressed: #sparse [Key]bool,
	keys_released: #sparse [Key]bool,
	keys_held: #sparse [Key]bool,
	keys_repeated: #sparse [Key]bool, // went down this frame, auto-repeats included; keys_pressed leaves the repeats out
	typed_text: [MAX_TEXT_INPUT]u8, // UTF-8 typed this frame (WM_CHAR)
	typed_text_length: int,
	typed_high_surrogate: u16, // the first half of a character outside the BMP, waiting for its second
	window_samples: i32, // set_window_samples: the swapchain's sample count, 1 when off
	close_confirmation: bool, // set_close_confirmation: the close button asks the game instead of closing
	minimum_window_size: [2]i32, // set_minimum_window_size, the drawing area in pixels; zero is no limit
	close_requested: bool, // the window's close button was pressed this frame (WM_CLOSE)

	mouse_wheel_value:i16,
	mouse_wheel_horizontal_value:i16, // positive is right; added up over the frame, like mouse_wheel_value
	cursor_shape:Cursor_Shape, // what set_cursor_shape asked for
	cursors:[Cursor_Shape]win.HCURSOR, // loaded at init; nil until then, and WM_SETCURSOR leaves the cursor alone while one is nil
	dropped_files:[dynamic]Dropped_File, // this frame's, paths on the heap; freed when the next frame starts
	mouse_position:[2]i32,
	mouse_pressed:[Mouse]bool,
	mouse_released:[Mouse]bool,
	mouse_held:[Mouse]bool,
	mouse_capture:Mouse_Capture,

	// GameInput
	gamepad_pressed: bit_set [Button],
	gamepad_released: bit_set [Button],
	gamepad_held: bit_set [Button],

	input:^gi.IGameInput,
	gamepad:^gi.IDevice,
	reading:^gi.IReading,
	left_thumbstick_axis:[2]f32,
	right_thumbstick_axis:[2]f32,
	left_trigger_value:f32,
	right_trigger_value:f32,

	// For feature parity; the controller on PC can also be a button as the 3DS
	// so added these as values to set the value where the trigger being >= to
	// will be considered "pressed"
	left_trigger_as_button_value:f32,
	right_trigger_as_button_value:f32,

	// D3D11
	device: ^d3d11.IDevice,
	device_context: ^d3d11.IDeviceContext,
	swapchain:^dxgi.ISwapChain1,
	swapchain_description:dxgi.SWAP_CHAIN_DESC1,
	factory:^dxgi.IFactory2,
	dxgi_device:^dxgi.IDevice1,
	dxgi_adapter:^dxgi.IAdapter,
	dxgi_description:^dxgi.ADAPTER_DESC,
	framebuffer:^d3d11.ITexture2D,
	depth_texture:^d3d11.ITexture2D,
	depth_view:^d3d11.IDepthStencilView,
	framebuffer_view: ^d3d11.IRenderTargetView,
	white_texture:^d3d11.ITexture2D,
	white_texture_view:^d3d11.IShaderResourceView,

	// Pipeline states; one is chosen per draw with set_render_state
	depth_states:[Depth_Mode]^d3d11.IDepthStencilState,
	blend_states:[Blend_Mode]^d3d11.IBlendState,
	rasterizer_states:[Cull_Mode]^d3d11.IRasterizerState,
	// The same with MultisampleEnable, for drawing into a multisampled target: that is what makes a line smooth there, but with one sample it
	// draws a line wider than a pixel, so a plain target keeps the first set
	multisampled_rasterizer_states:[Cull_Mode]^d3d11.IRasterizerState,
	shadow_map:Shadow_Map, // the caster's depth, drawn at camera_end when a light casts (shadow_windows.odin)
	camera_view_projection:matrix[4, 4]f32, // what camera_start set the frame constants to, which the shadow pass puts back
	drawing_multisampled:bool, // what the target being drawn into is, kept by bind_screen and bind_render_target for set_render_state
	samplers:[Filter_Mode]^d3d11.ISamplerState,

	// The three shaders, each with what it reads (render_windows.odin). `pipeline` (shaders/mesh.mbs) draws
	// everything unlit; while lighting is on, `lit_pipeline` (shaders/mesh_lit.mbs) draws lit meshes per pixel and
	// `vertex_lit_pipeline` (shaders/mesh_vertex_lit.mbs) per vertex, as each part's material says
	pipeline:Render_Pipeline,
	lit_pipeline:Render_Pipeline,
	vertex_lit_pipeline:Render_Pipeline,

	// Skinned meshes (G6): mesh_skinned.mbs unlit and mesh_skinned_lit.mbs per pixel. A skinned part asking for per-vertex
	// lighting is drawn per pixel (there is no per-vertex skinned shader), so a model looks the same on every target
	skinned_pipeline:Render_Pipeline,
	skinned_lit_pipeline:Render_Pipeline,
	skin_constants:^d3d11.IBuffer, // the joint palette of the draw, filled from mbi.skin_state in render_item

	// The constant buffers, shared by both pipelines: each binds the ones its reflection lists
	frame_constants:^d3d11.IBuffer,
	render_constants:^d3d11.IBuffer,
	game_constants:^d3d11.IBuffer, // the game's own uniforms, set by name with set_shader_value (mesh.mbs's)
	game_shadow:[]byte, // what game_constants holds, kept on the CPU so one value can change
	game_dirty:bool,
	lights_constants:^d3d11.IBuffer, // the lights block, filled from mbi.lighting at camera_end (light.odin)

	// The sky (skybox_windows.odin): its shader, and the one render_skybox recorded for the camera being drawn
	skybox:Skybox_State,

	// Fixed values the PC backend works with
	shader_format:Shader_Format,
	skin_settings:Skin_Settings,
}

/*
	The PC's half of `mbi`'s initial values (matchbox_info.odin sets `backend =
	BACKEND_DEFAULTS`). A constant because a global's initial value must be known at compile
	time, and the shared file can't name a DXGI format or a PC-only Vertex_Attribute
*/
BACKEND_DEFAULTS :: Backend_State {
	// The most joints one draw may use. **Revisit later:** the user plans a PC-only pass that raises this for PC games
	// at the cost of models that no longer compile to the other targets. It is a setting rather than shared code so
	// that raising it is this number and the shaders' JOINT_SLOT_COUNT (tools/mbsc/lighting.odin get_max_joints)
	skin_settings = {joint_limit = 256, layer_limit = 4},
	shader_format = {
		reflection_version = 1,
		vertex_attributes = {
			{"position", "[3]f32", .R32G32B32_FLOAT, u32(offset_of(Vertex, position)), false, false},
			{"texcoord", "[2]f32", .R32G32_FLOAT, u32(offset_of(Vertex, uv)), false, false},
			{"color", "[4]f32", .R32G32B32A32_FLOAT, u32(offset_of(Vertex, color)), false, false},
			{"normal", "[3]f32", .R32G32B32_FLOAT, u32(offset_of(Lit_Vertex, normal)), true, false},
			// Both are bytes read as 0..1 (a joint is scaled back to 0..255 in the shader: a UINT format would hand a float input the integer's bits)
			{"joints", "[4]f32", .R8G8B8A8_UNORM, u32(offset_of(Skinned_Vertex, joints)), true, true},
			{"weights", "[4]f32", .R8G8B8A8_UNORM, u32(offset_of(Skinned_Vertex, weights)), true, true},
		},
	},
}

/*What only a PC render target has besides its texture: the views the GPU draws through (render_target_windows.odin)*/
Backend_Render_Target :: struct {
	color_view:^d3d11.IRenderTargetView, // what is drawn into: the multisampled texture's when there is one, else `texture`'s own
	msaa_texture:^d3d11.ITexture2D, // nil unless the target is multisampled; resolved into `texture` by unbind_render_target
	depth_texture:^d3d11.ITexture2D,
	depth_view:^d3d11.IDepthStencilView,
}

/*What only a PC texture has: the D3D11 objects. Embedded in Texture with `using`*/
Backend_Texture :: struct {
	texture:^d3d11.ITexture2D,
	view:^d3d11.IShaderResourceView,
}
