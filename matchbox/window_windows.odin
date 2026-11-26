#+build windows

package matchbox


/*
	Window
	======
	This file handles the window creation events

	For Windows: this handles win32 and D3D11 Setup
*/

// Core
import win "core:sys/windows"

// Vendor
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import gi "vendor:windows/GameInput"


// Matchbox_Info :: struct {

// 	// General values
// 	did_resize:bool,
// 	asset_path:string, // General asset path for shared assets
// 	target_asset_path:string, // Asset path for pc specific assets

// 	// Win32 Related Values
// 	window:win.HWND,
// 	is_running:bool,
// 	window_size:[4]i32,

// 	keys_pressed: #sparse [Key]bool,
// 	keys_released: #sparse [Key]bool,
// 	keys_held: #sparse [Key]bool,

// 	event_message:^win.MSG,
// 	mouse_wheel_value:i16,
// 	mouse_position:[2]i32,

// 	mouse_pressed:[Mouse]bool,
// 	mouse_released:[Mouse]bool,
// 	mouse_held:[Mouse]bool,

// 	// GameInput Values
// 	gamepad_pressed: bit_set [Button],
// 	gamepad_released: bit_set [Button],
// 	gamepad_held: bit_set [Button],

// 	input:^gi.IGameInput,
// 	gamepad:^gi.IDevice,
// 	reading:^gi.IReading,
// 	left_thumbstick_axis:[2]f32,
// 	right_thumbstick_axis:[2]f32,
// 	left_trigger_value:f32,
// 	right_trigger_value:f32,

// 	// For feature parity; the controller on PC can also be a button as the 3DS
// 	// so added these as values to set the value where the trigger being >= to
// 	// will be considered "pressed"
// 	left_trigger_as_button_value:f32,
// 	right_trigger_as_button_value:f32,

// 	//D3D11 Values
// 	device: ^d3d11.IDevice,
// 	device_context: ^d3d11.IDeviceContext,
// 	swapchain:^dxgi.ISwapChain1,
// 	swapchain_description:dxgi.SWAP_CHAIN_DESC1,
// 	factory:^dxgi.IFactory2,
// 	dxgi_device:^dxgi.IDevice1,
// 	dxgi_adapter:^dxgi.IAdapter,
// 	dxgi_description:^dxgi.ADAPTER_DESC,
// 	framebuffer:^d3d11.ITexture2D,
// 	depth_texture:^d3d11.ITexture2D,
// 	depth_view:^d3d11.IDepthStencilView,
// 	framebuffer_view: ^d3d11.IRenderTargetView,
// 	white_texture:^d3d11.ITexture2D,

// 	// Pipeline states; one is chosen per draw with set_render_state
// 	depth_states:[Depth_Mode]^d3d11.IDepthStencilState,
// 	blend_states:[Blend_Mode]^d3d11.IBlendState,
// 	rasterizer_states:[Cull_Mode]^d3d11.IRasterizerState,
// 	samplers:[Filter_Mode]^d3d11.ISamplerState,
// 	view:matrix[4,4]f32,
// 	camera_active:bool,
// 	screen_pass:bool,
// 	screen_height:f32,
// 	bottom_screen_layout:Bottom_Screen_Layout, // HIDDEN until the game asks; see set_bottom_screen
// 	discard_pass:bool, // the pass in progress is the hidden bottom screen: queued, never drawn
// 	opaque_items:[dynamic]Render_Item,
// 	transparent_items:[dynamic]Render_Item,

// 	white_texture_view:^d3d11.IShaderResourceView,

// 	// 3D Pipeline | shaders/mesh.pc.hlsl (generated from shaders/mesh.mbs)
// 	shader_src:[]u8,
// 	vertex_shader:^d3d11.IVertexShader,
// 	vertex_shader_blob: ^d3d11.IBlob,
// 	pixel_shader:^d3d11.IPixelShader,
// 	pixel_shader_blob:^d3d11.IBlob,
// 	input_layout:^d3d11.IInputLayout,
// 	// test_vertex_buffer:^d3d11.IBuffer, // temporary for testing
// 	frame_constants:^d3d11.IBuffer,
// 	render_constants:^d3d11.IBuffer,
// 	game_constants:^d3d11.IBuffer, // the game's own uniforms, set by name with set_shader_value
// 	game_shadow:[]byte, // what game_constants holds, kept on the CPU so one value can change
// 	game_dirty:bool,
// 	reflection:Shader_Reflection, // what the shader needs, from shaders/mesh.pc.refl
	

// 	// Sprites
// 	sprite_mesh:Mesh,
// 	triangle_mesh:Mesh,
// 	circle_mesh:Mesh,
// 	pixel_scale:f32,

// 	timestamp:Timestamp,

// 	// Fixed values the engine works with, grouped by what they belong to
// 	font_settings:Font_Settings,
// 	screen_settings:Screen_Settings,
// 	shader_format:Shader_Format,
// }

// /*
// 	The one global (CLAUDE.md). The settings are given their values here rather than in
// 	`init`: a value set here is right from the first line of the program, and under
// 	`odin test`, where `init` never runs, as well
// */
// mbi := Matchbox_Info {
// 	font_settings = {
// 		atlas_min_size = 256,
// 		atlas_max_size = 4096,
// 		first_glyph = 32,
// 		line_spacing = 0.15,
// 	},
// 	screen_settings = {
// 		default_height = 12,
// 		bottom_screen_aspect = 320.0 / 240.0,
// 	},
// 	shader_format = {
// 		reflection_version = 1,
// 		vertex_attributes = {
// 			{"position", "[3]f32", .R32G32B32_FLOAT, u32(offset_of(Vertex, position))},
// 			{"texcoord", "[2]f32", .R32G32_FLOAT, u32(offset_of(Vertex, uv))},
// 			{"color", "[4]f32", .R32G32B32A32_FLOAT, u32(offset_of(Vertex, color))},
// 		},
// 	},
// }

/*Initialize the core of Matchbox; from Windows, to D3D11, etc*/
init :: proc(title:string, width:i32, height:i32) {

	win.SetProcessDPIAware()

	mbi.is_running = true
	mbi.left_trigger_as_button_value = 0.2
	mbi.right_trigger_as_button_value = 0.2
	mbi.asset_path = "assets/"
	mbi.target_asset_path = "assets/pc/"
	mbi.window_size = {width, height, 0, 0}

	rectangle:win.RECT = {left = 0, top = 0, right = width, bottom = height}
	mbi.screen_height = mbi.screen_settings.default_height

	// Create a handle to the instance of the application - The thing the OS uses to ID the executable
	instance := win.HINSTANCE(win.GetModuleHandleW(nil)) // Create Instance

	// Create the attributes that the window will use when it's registered
	window_class: win.WNDCLASSEXW = {
		cbSize = size_of(win.WNDCLASSEXW),
		style = win.CS_OWNDC | win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc = window_event_proc,
		cbClsExtra = 0,
		cbWndExtra = 0,
		hInstance = instance,
		hIcon = nil,
		hCursor = nil,
		hbrBackground = nil,
		lpszMenuName = nil,
		lpszClassName = win.L("Basic_Game_Class"),
		hIconSm = nil,
	}

	win.RegisterClassExW(&window_class)
	win.AdjustWindowRect(lpRect = &rectangle, dwStyle = win.WS_OVERLAPPEDWINDOW, bMenu = win.FALSE) // Adjust window


	// Non Breaking issue: CreateWindowExW will immediate call the wm.ShowWindow(...) proc to present the window to the screen, if the `Y` is `win.CW_USEDEFUALT`
	// My problem is that this will happen before d3d11 is even initialzed, let alone setup. Thus, the window is white before it's set by `clear_background`
	// I'd like to find a way to solve this cause setting Y to 0 and moving manually showing the window at the end of `init` has the same issue
	mbi.window = win.CreateWindowExW(
		dwExStyle = 0,
		lpClassName = window_class.lpszClassName,
		lpWindowName = win.utf8_to_wstring(title),  //win.L("Basic Window"),
		dwStyle = win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE | win.WS_SYSMENU,
		X = win.CW_USEDEFAULT,
		Y = win.CW_USEDEFAULT,
		nWidth = rectangle.right - rectangle.left,
		nHeight = rectangle.bottom - rectangle.top,
		hWndParent = nil,
		hMenu = nil,
		hInstance = instance,
		lpParam = nil,
	)

	if mbi.window == nil {
		return
	}

	// Setup D3D11
	{
		feature_levels := []d3d11.FEATURE_LEVEL {d3d11.FEATURE_LEVEL._11_0}
		creation_flags := d3d11.CREATE_DEVICE_FLAGS {.BGRA_SUPPORT}

		when ODIN_DEBUG {creation_flags += {.DEBUG}} // If in debug mode; enable debug for d3d11

		result := d3d11.CreateDevice(
			pAdapter = nil,
			DriverType = .HARDWARE,
			Software = nil,
			Flags = creation_flags,
			pFeatureLevels = raw_data(feature_levels),
			FeatureLevels = u32(len(feature_levels)),
			SDKVersion = d3d11.SDK_VERSION,
			ppDevice = &mbi.device,
			pFeatureLevel = nil,
			ppImmediateContext = &mbi.device_context,
		)


		ensure(win.SUCCEEDED(result), "CreateDevice failed")

	}


	// Debug Layer
	when ODIN_DEBUG {
		device_debug:^d3d11.IDebug
		mbi.device->QueryInterface(d3d11.IDebug_UUID, (^rawptr)(&device_debug))

		if device_debug != nil {
			info_queue:^d3d11.IInfoQueue
			result := device_debug->QueryInterface(d3d11.IInfoQueue_UUID, (^rawptr)(&info_queue))
			if win.SUCCEEDED(result) {
				info_queue->SetBreakOnSeverity(.CORRUPTION, true)
				info_queue->SetBreakOnSeverity(.ERROR, true)


				allow_severities := []d3d11.MESSAGE_SEVERITY {.CORRUPTION, .ERROR, .INFO}

				filter := d3d11.INFO_QUEUE_FILTER {
					AllowList = {
						NumSeverities = u32(len(allow_severities)),
						pSeverityList = raw_data(allow_severities),
					},
				}
				info_queue->AddStorageFilterEntries(&filter)
				info_queue->Release()
			}
			device_debug->Release()
		}
	}

	// Create swapchain
	{
		{
			result := mbi.device->QueryInterface(dxgi.IDevice1_UUID, (^rawptr)(&mbi.dxgi_device))
			ensure(win.SUCCEEDED(result), "DXGI device interface query failed")

			result = mbi.dxgi_device->GetAdapter(&mbi.dxgi_adapter)
			ensure(win.SUCCEEDED(result), "DXGI adapter interface query failed")

			mbi.dxgi_adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&mbi.factory))
		}

		mbi.swapchain_description.Width = 0
		mbi.swapchain_description.Height = 0
		mbi.swapchain_description.Format = .B8G8R8A8_UNORM_SRGB
		mbi.swapchain_description.SampleDesc = {Count = 1,Quality = 0}
		mbi.swapchain_description.BufferUsage = {.RENDER_TARGET_OUTPUT}
		mbi.swapchain_description.BufferCount = 2
		mbi.swapchain_description.Scaling = .STRETCH
		mbi.swapchain_description.SwapEffect = .DISCARD
		mbi.swapchain_description.AlphaMode = .UNSPECIFIED
		mbi.swapchain_description.Flags = {}

		result := mbi.factory->CreateSwapChainForHwnd(
			pDevice = mbi.device,
			hWnd = mbi.window,
			pDesc = &mbi.swapchain_description,
			pFullscreenDesc = nil,
			pRestrictToOutput = nil,
			ppSwapChain = &mbi.swapchain,
		)

		ensure(win.SUCCEEDED(result), "CreateSwapChain failed")
	}
	{
		result := mbi.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&mbi.framebuffer))
		ensure(win.SUCCEEDED(result), "Get Framebuffer failed")

		result = mbi.device->CreateRenderTargetView(mbi.framebuffer, nil, &mbi.framebuffer_view)
	}

	{
		create_depth_buffer()
		create_pipeline()

		sprite_vertices, sprite_indices := create_quad_geometry()
		mbi.sprite_mesh = create_mesh(sprite_vertices, sprite_indices)
		delete(sprite_vertices)
		delete(sprite_indices)


		triangle_vertices, triangle_indices := create_triangle_geometry()
		mbi.triangle_mesh = create_mesh(triangle_vertices, triangle_indices)
		delete(triangle_vertices)
		delete(triangle_indices)

		circle_vertices, circle_indices := create_circle_geometry()
		mbi.circle_mesh = create_mesh(circle_vertices, circle_indices)
		delete(circle_vertices)
		delete(circle_indices)		
	}

	create_white_texture()
	
	// The frame clock counts from here (clock.odin)
	frequency, counter:win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&frequency)
	win.QueryPerformanceCounter(&counter)
	start_clock(&mbi.clock, u64(counter), u64(frequency))


	result := gi.Create(&mbi.input)
	if win.SUCCEEDED(result) == false {
	}



	// win.ShowWindow(mbi.window, win.SW_SHOW)

}

/*Returns true if the window is running; other returns fale -> Almost always will return true*/
is_running :: proc() -> bool {
	return mbi.is_running
}

/*Stops running the application*/
stop_running :: proc() {
	mbi.is_running = false
}

/*Cleans up resources created by Matchbox*/
cleanup :: proc() {

	// Win32
	release_mouse_capture() // the clip and the hidden cursor outlive a program that exits holding them

	// GameInput -- User may not have a controller so the values can be nil by cleanup call
	if mbi.gamepad != nil do mbi.gamepad->Release()
	if mbi.input != nil do mbi.input->Release() // -> Left commented out as something causes this to wait for 8 seconds and not sure what

	// D3D11

	destroy_mesh(mbi.triangle_mesh)
	destroy_mesh(mbi.circle_mesh)
	destroy_mesh(mbi.sprite_mesh)
	destroy_pipeline()
	// mbi.blend_state->Release()
	mbi.white_texture_view->Release()
	mbi.white_texture->Release()
	destroy_depth_buffer()
	mbi.framebuffer->Release()
	mbi.framebuffer_view->Release()
	mbi.dxgi_adapter->Release()
	mbi.dxgi_device->Release()
	mbi.factory->Release()
	mbi.swapchain->Release()
	mbi.device_context->Release()
	mbi.device->Release()
}
