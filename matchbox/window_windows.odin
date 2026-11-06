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
import "vendor:directx/d3d_compiler"
import "vendor:directx/d3d_common"
import gi "vendor:windows/GameInput"


Timestamp :: struct {
	fixed_timestamp:f64,
	accumulator:f64,
	deltatime:f64,
	current_time:win.LARGE_INTEGER,
	last_time: win.LARGE_INTEGER,
	frequency: win.LARGE_INTEGER,
	counter: win.LARGE_INTEGER,
}
timestamp:Timestamp

Matchbox_Info :: struct {

	// General values
	did_resize:bool,
	asset_path:string, // required as otherwise loading assets between targets will be messy

	// Win32 Related Values
	window:win.HWND,
	is_running:bool,
	window_size:[2]i32,

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
	framebuffer_view: ^d3d11.IRenderTargetView,
	sampler:^d3d11.ISamplerState,
	white_texture:^d3d11.ITexture2D,
	blend_state:^d3d11.IBlendState,

	// Shaders
	shader_src:[]u8,
	vertex_shader:^d3d11.IVertexShader,
	vertex_shader_blob: ^d3d11.IBlob,
	compile_errors:^d3d11.IBlob, // Resused for vertex and pixel shader
	pixel_shader:^d3d11.IPixelShader,
	pixel_shader_blob:^d3d11.IBlob,
	input_layout:^d3d11.IInputLayout, // The layout of the input struct VS_Input in the shader
	vertex_buffer:^d3d11.IBuffer,
	constant_buffer:^d3d11.IBuffer,
	white_texture_view:^d3d11.IShaderResourceView,
	
	// Shapes
	vertex_count:u32,
	vertex_stride:u32,
	vertex_offset:u32,
}

mbi:Matchbox_Info

/*Initialize the core of Matchbox; from Windows, to D3D11, etc*/
init :: proc(title:string, width:i32, height:i32) {

	mbi.is_running = true
	mbi.left_trigger_as_button_value = 0.2
	mbi.right_trigger_as_button_value = 0.2
	mbi.asset_path = "assets/pc/"
	mbi.window_size = {width, height}

	rect:win.RECT = {left = 0, top = 0, right = width, bottom = height}

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

	mbi.shader_src = #load("shaders/shaders.hlsl")

	{
		res := d3d_compiler.Compile(
			pSrcData = raw_data(mbi.shader_src),
			SrcDataSize = uint(len(mbi.shader_src)),
			pSourceName = "shaders/shaders.hlsl", // For debug messages -- not required
			pDefines = nil,
			pInclude = nil,
			pEntrypoint = "vertex_main",
			pTarget = "vs_5_0",
			Flags1 = 0,
			Flags2 = 0,
			ppCode = &mbi.vertex_shader_blob,
			ppErrorMsgs = &mbi.compile_errors,
		)

		if win.FAILED(res) {
			if mbi.compile_errors != nil {
				error_str := mbi.compile_errors->GetBufferPointer()
				mbi.compile_errors->Release()
			}

			ensure(win.SUCCEEDED(res), "Vertex shader compilation failed")
		}

		res = mbi.device->CreateVertexShader(
			pShaderBytecode = mbi.vertex_shader_blob->GetBufferPointer(),
			BytecodeLength = mbi.vertex_shader_blob->GetBufferSize(),
			pClassLinkage = nil,
			ppVertexShader = &mbi.vertex_shader,
		)
		ensure(win.SUCCEEDED(res), "Vertex shader creation failed")
	}

	// Create Pixel Shader
	{
		res := d3d_compiler.Compile(
			pSrcData = raw_data(mbi.shader_src),
			SrcDataSize = uint(len(mbi.shader_src)),
			pSourceName = "shaders/shaders.hlsl", // For debug messages -- not required
			pDefines = nil,
			pInclude = nil,
			pEntrypoint = "pixel_main",
			pTarget = "ps_5_0",
			Flags1 = 0,
			Flags2 = 0,
			ppCode = &mbi.pixel_shader_blob,
			ppErrorMsgs = &mbi.compile_errors,
		)

		if win.FAILED(res) {
			if mbi.compile_errors != nil {
				error_str := mbi.compile_errors->GetBufferPointer()
				mbi.compile_errors->Release()
			}

			ensure(win.SUCCEEDED(res), "Pixel shader compilation failed")
		}


		res = mbi.device->CreatePixelShader(
			pShaderBytecode = mbi.pixel_shader_blob->GetBufferPointer(),
			BytecodeLength = mbi.pixel_shader_blob->GetBufferSize(),
			pClassLinkage = nil,
			ppPixelShader = &mbi.pixel_shader,
		)
		ensure(win.SUCCEEDED(res), "Pixel shader creation failed")
	}

	// Create input layout
	{
		input_element_descs := []d3d11.INPUT_ELEMENT_DESC {
			{
				SemanticName = "position",
				SemanticIndex = 0,
				Format = .R32G32_FLOAT,
				InputSlot = 0,
				AlignedByteOffset = 0,
				InputSlotClass = .VERTEX_DATA,
				InstanceDataStepRate = 0,
			},
			{

				SemanticName = "color",
				SemanticIndex = 0,
				Format = .R32G32B32A32_FLOAT,
				InputSlot = 0,
				AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
				InputSlotClass = .VERTEX_DATA,
				InstanceDataStepRate = 0,
			},
			{
				SemanticName = "texcoord",
				SemanticIndex = 0,
				Format = .R32G32_FLOAT,
				InputSlot = 0,
				AlignedByteOffset = d3d11.APPEND_ALIGNED_ELEMENT,
				InputSlotClass = .VERTEX_DATA,
				InstanceDataStepRate = 0,
			},
		}


        res := mbi.device->CreateInputLayout(
                pInputElementDescs                = raw_data(input_element_descs),
                NumElements                       = u32(len(input_element_descs)),
                pShaderBytecodeWithInputSignature = mbi.vertex_shader_blob->GetBufferPointer(),
                BytecodeLength                    = mbi.vertex_shader_blob->GetBufferSize(),
                ppInputLayout                     = &mbi.input_layout
        )
        ensure(win.SUCCEEDED(res), "Input layout creation failed")
	}

	{
		vertex_buffer_desc := d3d11.BUFFER_DESC {
			ByteWidth = MAX_BATCH_VERTICIES * size_of(Vertex),
			Usage = .DYNAMIC,
			BindFlags = {.VERTEX_BUFFER},
			CPUAccessFlags = {.WRITE},
		}

		res := mbi.device->CreateBuffer(
			pDesc = &vertex_buffer_desc,
			pInitialData = nil,
			ppBuffer = &batch.gpu_buffer,
		)

		ensure(win.SUCCEEDED(res), "Create VertexBuffer Failed")



		// TODO: What reserve does and how it works "You also reserve(&batch.vertices, MAX_BATCH_VERTICES) so appending never reallocates."

	}
	
	{
		sampler_desc := d3d11.SAMPLER_DESC {
			Filter = .MIN_MAG_MIP_POINT,
			AddressU = .BORDER,
			AddressV = .BORDER,
			AddressW = .BORDER,
			ComparisonFunc = .NEVER,
			BorderColor = {1, 1,1, 0},
		}

		res := mbi.device->CreateSamplerState(&sampler_desc, &mbi.sampler)
		ensure(win.SUCCEEDED(res), "Create SamplerState Failed")
	}


	{
		blend_desc:d3d11.BLEND_DESC

		blend_desc.RenderTarget[0] = {
			BlendEnable = true,
			SrcBlend = .SRC_ALPHA,
			DestBlend = .INV_SRC_ALPHA,
			BlendOp = .ADD,
			SrcBlendAlpha = .ONE,
			DestBlendAlpha = .INV_SRC_ALPHA,
			BlendOpAlpha = .ADD,
			RenderTargetWriteMask = 0xF // R | G | B | A
		}

		res := mbi.device->CreateBlendState(&blend_desc, &mbi.blend_state)
		ensure(win.SUCCEEDED(res), "Create BlendState Failed")
		
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

		batch.current_texture_view = mbi.white_texture_view
	}	
	
	{
		constant_buffer_desc := d3d11.BUFFER_DESC {
			ByteWidth = size_of(Constants),
			Usage = .DYNAMIC,
			BindFlags = {.CONSTANT_BUFFER},
			CPUAccessFlags = {.WRITE},
		}

		res := mbi.device->CreateBuffer(
			pDesc = &constant_buffer_desc,
			pInitialData = nil,
			ppBuffer = &mbi.constant_buffer,
		)

		ensure(win.SUCCEEDED(res), "Create ConstantBuffer Failed")

	}

	// Setup the initial frequency and counter for delta time
	win.QueryPerformanceFrequency(&timestamp.frequency)
	win.QueryPerformanceCounter(&timestamp.last_time)


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
	mbi.blend_state->Release()
	mbi.white_texture_view->Release()
	mbi.white_texture->Release()
	mbi.constant_buffer->Release()
	mbi.sampler->Release()
	mbi.input_layout->Release()
	mbi.pixel_shader_blob->Release()
	mbi.pixel_shader->Release()
	mbi.vertex_shader_blob->Release()
	mbi.vertex_shader->Release()
	mbi.framebuffer->Release()
	mbi.framebuffer_view->Release()
	mbi.dxgi_adapter->Release()
	mbi.dxgi_device->Release()
	mbi.factory->Release()
	mbi.swapchain->Release()
	mbi.device_context->Release()
	mbi.device->Release()
}
