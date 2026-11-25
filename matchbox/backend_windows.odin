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

Backend_State :: struct {
	// Win32
	window:win.HWND,
	event_message:^win.MSG,

	keys_pressed: #sparse [Key]bool,
	keys_released: #sparse [Key]bool,
	keys_held: #sparse [Key]bool,

	mouse_wheel_value:i16,
	mouse_position:[2]i32,
	mouse_pressed:[Mouse]bool,
	mouse_released:[Mouse]bool,
	mouse_held:[Mouse]bool,

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
	samplers:[Filter_Mode]^d3d11.ISamplerState,

	// The three shaders, each with what it reads (render_windows.odin). `pipeline` (shaders/mesh.mbs) draws
	// everything unlit; while lighting is on, `lit_pipeline` (shaders/mesh_lit.mbs) draws lit meshes per pixel and
	// `vertex_lit_pipeline` (shaders/mesh_vertex_lit.mbs) per vertex, as each part's material says
	pipeline:Render_Pipeline,
	lit_pipeline:Render_Pipeline,
	vertex_lit_pipeline:Render_Pipeline,

	// The constant buffers, shared by both pipelines: each binds the ones its reflection lists
	frame_constants:^d3d11.IBuffer,
	render_constants:^d3d11.IBuffer,
	game_constants:^d3d11.IBuffer, // the game's own uniforms, set by name with set_shader_value (mesh.mbs's)
	game_shadow:[]byte, // what game_constants holds, kept on the CPU so one value can change
	game_dirty:bool,
	lights_constants:^d3d11.IBuffer, // the lights block, filled from mbi.lighting at camera_end (light.odin)

	// Fixed values the PC backend works with
	shader_format:Shader_Format,
}

/*
	The PC's half of `mbi`'s initial values (matchbox_info.odin sets `backend =
	BACKEND_DEFAULTS`). A constant because a global's initial value must be known at compile
	time, and the shared file can't name a DXGI format or a PC-only Vertex_Attribute
*/
BACKEND_DEFAULTS :: Backend_State {
	shader_format = {
		reflection_version = 1,
		vertex_attributes = {
			{"position", "[3]f32", .R32G32B32_FLOAT, u32(offset_of(Vertex, position)), false},
			{"texcoord", "[2]f32", .R32G32_FLOAT, u32(offset_of(Vertex, uv)), false},
			{"color", "[4]f32", .R32G32B32A32_FLOAT, u32(offset_of(Vertex, color)), false},
			{"normal", "[3]f32", .R32G32B32_FLOAT, u32(offset_of(Lit_Vertex, normal)), true},
		},
	},
}

/*What only a PC texture has: the D3D11 objects. Embedded in Texture with `using`*/
Backend_Texture :: struct {
	texture:^d3d11.ITexture2D,
	view:^d3d11.IShaderResourceView,
}
