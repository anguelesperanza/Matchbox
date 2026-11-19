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


Timestamp :: struct {
	fixed_timestamp:f64,
	accumulator:f64,
	deltatime:f64,
	current_time:win.LARGE_INTEGER,
	last_time: win.LARGE_INTEGER,
	frequency: win.LARGE_INTEGER,
	counter: win.LARGE_INTEGER,
	start_counter: win.LARGE_INTEGER, // when the window was created; frame.time counts from here
}
timestamp:Timestamp

Matchbox_Info :: struct {

	// General values
	did_resize:bool,
	asset_path:string, // General asset path for shared assets
	target_asset_path:string, // Asset path for pc specific assets

	// Win32 Related Values
	window:win.HWND,
	is_running:bool,
	window_size:[4]i32,

	keys_pressed: #sparse [Key]bool,
	keys_released: #sparse [Key]bool,
	keys_held: #sparse [Key]bool,

	event_message:^win.MSG,
	mouse_wheel_value:i16,
	mouse_position:[2]i32,

	mouse_pressed:[Mouse]bool,
	mouse_released:[Mouse]bool,
	mouse_held:[Mouse]bool,

	// GameInput Values
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

	//D3D11 Values
	device: ^d3d11.IDevice,
	device_context: ^d3d11.IDeviceContext,
	swapchain:^dxgi.ISwapChain1,
	swapchain_desc:dxgi.SWAP_CHAIN_DESC1,
	factory:^dxgi.IFactory2,
	dxgi_device:^dxgi.IDevice1,
	dxgi_adapter:^dxgi.IAdapter,
	dxgi_desc:^dxgi.ADAPTER_DESC,
	framebuffer:^d3d11.ITexture2D,
	depth_texture:^d3d11.ITexture2D,
	depth_view:^d3d11.IDepthStencilView,
	framebuffer_view: ^d3d11.IRenderTargetView,
	white_texture:^d3d11.ITexture2D,

	// Pipeline states; one is chosen per draw with set_render_state
	depth_states:[Depth_Mode]^d3d11.IDepthStencilState,
	blend_states:[Blend_Mode]^d3d11.IBlendState,
	rasterizer_states:[Cull_Mode]^d3d11.IRasterizerState,
	samplers:[Filter_Mode]^d3d11.ISamplerState,
	view:matrix[4,4]f32,
	camera_active:bool,
	screen_pass:bool,
	screen_height:f32,
	bottom_screen_layout:Bottom_Screen_Layout, // HIDDEN until the game asks; see set_bottom_screen
	discard_pass:bool, // the pass in progress is the hidden bottom screen: queued, never drawn
	opaque_items:[dynamic]Draw_Item,
	transparent_items:[dynamic]Draw_Item,

	white_texture_view:^d3d11.IShaderResourceView,

	// 3D Pipeline | shaders/mesh.pc.hlsl (generated from shaders/mesh.mbs)
	shader_src:[]u8,
	vertex_shader:^d3d11.IVertexShader,
	vertex_shader_blob: ^d3d11.IBlob,
	pixel_shader:^d3d11.IPixelShader,
	pixel_shader_blob:^d3d11.IBlob,
	input_layout:^d3d11.IInputLayout,
	// test_vertex_buffer:^d3d11.IBuffer, // temporary for testing
	frame_constants:^d3d11.IBuffer,
	draw_constants:^d3d11.IBuffer,
	game_constants:^d3d11.IBuffer, // the game's own uniforms, set by name with set_shader_value
	game_shadow:[]byte, // what game_constants holds, kept on the CPU so one value can change
	game_dirty:bool,
	reflection:Shader_Reflection, // what the shader needs, from shaders/mesh.pc.refl
	

	// Sprites
	sprite_mesh:Mesh,
	triangle_mesh:Mesh,
	circle_mesh:Mesh,
	pixel_scale:f32,
	
}

mbi:Matchbox_Info

/*Initialize the core of Matchbox; from Windows, to D3D11, etc*/
init :: proc(title:string, width:i32, height:i32) {

	win.SetProcessDPIAware()

	mbi.is_running = true
	mbi.left_trigger_as_button_value = 0.2
	mbi.right_trigger_as_button_value = 0.2
	mbi.asset_path = "assets/"
	mbi.target_asset_path = "assets/pc/"
	mbi.window_size = {width, height, 0, 0}

	rect:win.RECT = {left = 0, top = 0, right = width, bottom = height}
	mbi.screen_height = DEFAULT_SCREEN_HEIGHT

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
	win.AdjustWindowRect(lpRect = &rect, dwStyle = win.WS_OVERLAPPEDWINDOW, bMenu = win.FALSE) // Adjust window

	mbi.window = win.CreateWindowExW(
		dwExStyle = 0,
		lpClassName = window_class.lpszClassName,
		lpWindowName = win.utf8_to_wstring(title),  //win.L("Basic Window"),
		dwStyle = win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE | win.WS_SYSMENU,
		X = win.CW_USEDEFAULT,
		Y = win.CW_USEDEFAULT,
		nWidth = rect.right - rect.left,
		nHeight = rect.bottom - rect.top,
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

		res := d3d11.CreateDevice(
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


		ensure(win.SUCCEEDED(res), "CreateDevice failed")

	}


	// Debug Layer
	when ODIN_DEBUG {
		device_debug:^d3d11.IDebug
		mbi.device->QueryInterface(d3d11.IDebug_UUID, (^rawptr)(&device_debug))

		if device_debug != nil {
			info_queue:^d3d11.IInfoQueue
			res := device_debug->QueryInterface(d3d11.IInfoQueue_UUID, (^rawptr)(&info_queue))
			if win.SUCCEEDED(res) {
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
			res := mbi.device->QueryInterface(dxgi.IDevice1_UUID, (^rawptr)(&mbi.dxgi_device))
			ensure(win.SUCCEEDED(res), "DXGI device interface query failed")

			res = mbi.dxgi_device->GetAdapter(&mbi.dxgi_adapter)
			ensure(win.SUCCEEDED(res), "DXGI adapter interface query failed")

			mbi.dxgi_adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&mbi.factory))
		}

		mbi.swapchain_desc.Width = 0
		mbi.swapchain_desc.Height = 0
		mbi.swapchain_desc.Format = .B8G8R8A8_UNORM_SRGB
		mbi.swapchain_desc.SampleDesc = {Count = 1,Quality = 0}
		mbi.swapchain_desc.BufferUsage = {.RENDER_TARGET_OUTPUT}
		mbi.swapchain_desc.BufferCount = 2
		mbi.swapchain_desc.Scaling = .STRETCH
		mbi.swapchain_desc.SwapEffect = .DISCARD
		mbi.swapchain_desc.AlphaMode = .UNSPECIFIED
		mbi.swapchain_desc.Flags = {}

		res := mbi.factory->CreateSwapChainForHwnd(
			pDevice = mbi.device,
			hWnd = mbi.window,
			pDesc = &mbi.swapchain_desc,
			pFullscreenDesc = nil,
			pRestrictToOutput = nil,
			ppSwapChain = &mbi.swapchain,
		)

		ensure(win.SUCCEEDED(res), "CreateSwapChain failed")
	}
	{
		res := mbi.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&mbi.framebuffer))
		ensure(win.SUCCEEDED(res), "Get Framebuffer failed")

		res = mbi.device->CreateRenderTargetView(mbi.framebuffer, nil, &mbi.framebuffer_view)
	}

	{
		create_depth_buffer()
		create_pipeline()

		sprite_vertices, sprite_indices := mesh_quad()
		mbi.sprite_mesh = create_mesh(sprite_vertices, sprite_indices)
		delete(sprite_vertices)
		delete(sprite_indices)


		triangle_vertices, triangle_indices := mesh_triangle()
		mbi.triangle_mesh = create_mesh(triangle_vertices, triangle_indices)
		delete(triangle_vertices)
		delete(triangle_indices)

		circle_vertices, circle_indices := mesh_circle()
		mbi.circle_mesh = create_mesh(circle_vertices, circle_indices)
		delete(circle_vertices)
		delete(circle_indices)		
	}

	{
		pixel := [4]u8{255, 255, 255, 255}

		desc := d3d11.TEXTURE2D_DESC {
			Width = 1, Height = 1, MipLevels = 1, ArraySize = 1,
			Format = .R8G8B8A8_UNORM,
			Usage = .IMMUTABLE,
			BindFlags = {.SHADER_RESOURCE},
			SampleDesc = {Count = 1},
		}
		data := d3d11.SUBRESOURCE_DATA{pSysMem = &pixel, SysMemPitch = 4}

		res := mbi.device->CreateTexture2D(&desc, &data, &mbi.white_texture)
		ensure(win.SUCCEEDED(res), "Create white texture failed")
		res = mbi.device->CreateShaderResourceView(mbi.white_texture, nil, &mbi.white_texture_view)
		ensure(win.SUCCEEDED(res), "Create white texture view failed")

	}	
	
	// Setup the initial frequency and counter for delta time
	win.QueryPerformanceFrequency(&timestamp.frequency)
	win.QueryPerformanceCounter(&timestamp.last_time)
	timestamp.start_counter = timestamp.last_time


	result := gi.Create(&mbi.input)
	if win.SUCCEEDED(result) == false {
	}

}

/*Returns true if the window is running; other returns fale -> Almost always will return true*/
is_running :: proc() -> bool {
	return mbi.is_running
}

/*Stops running the application*/
stop_running :: proc() {
	mbi.is_running = false
}

/*Returns the delta time value*/
get_delta_time :: proc() -> (dt:f32) {
	/*In C, a LARGE_INTEGER is a struct, In Odin, it's a c_longlong --> an f64*/
	now:win.LARGE_INTEGER
	win.QueryPerformanceCounter(lpPerformanceCount = &now)
	dt = f32(f64(now - timestamp.last_time) / cast(f64)timestamp.frequency)
	timestamp.last_time = now
	return dt
}

/*Cleans up resources created by Matchbox*/
cleanup :: proc() {

	// Win32
	win.ReleaseCapture()

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
