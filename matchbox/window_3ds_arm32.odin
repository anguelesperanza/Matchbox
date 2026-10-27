package matchbox


/*
	Window -- 3DS
	======
	This file handles the window creation events

	On the 3DS this sets the intial Ctru and Citro3D Defaults
	-- Citro2D is built on top of Citro3D so don't need to set Citro2D defaults

*/

// Core
import "o3dx/ctru"
import "o3dx/c3d"


// Constants
DISPLAY_TRANSFER_FLAGS :: u32(0x1000)


Timestamp :: struct {
	last_time:u64,
}
timestamp:Timestamp

Matchbox_Info :: struct {

	// General values
	is_running:bool,
	// logger:log.Logger,
	did_resize:bool,
	top_screen:rawptr,
	bottom_screen:rawptr,
	is_keys_pressed: #sparse [Key]bool,

	// Shaders
	shader_buffer:rawptr,
	prog:ctru.shaderProgram_s,
	dvlb:^ctru.DVLB_s,

	// Vertex
	vbo_data:rawptr,
    projection: c3d.Mtx,
	uloc_proj:i32,
	vertices:[MAX_BATCH_VERTICES]Vertex,
	vertex_count:u32,
}

mbi:Matchbox_Info


/*Initialize the core of Matchbox for the target platform*/
init :: proc(title:string, width:i32, height:i32) {

	mbi.is_running = true

	// mbi.logger = log.create_console_logger()
	// context.logger = mbi.logger
	
    romfs_rc := ctru.romfsInit()
    ctru.gfxInitDefault()
    c3d.Init(c3d.C3D_DEFAULT_CMDBUF_SIZE)
    ctru.consoleInit(ctru.GFX_BOTTOM, nil)
    ctru.printf("\x1b[5;1HromfsInit rc: 0x%08lX", romfs_rc)


    mbi.top_screen = c3d.RenderTargetCreate(
    	width = 240,
    	height = 400,
    	colorFmt = .RGBA8,
    	depthFmt = c3d.DEPTHTYPE_DEPTH24_STENCIL8
    )
    
	c3d.RenderTargetSetOutput(
		target = mbi.top_screen,
		screen = ctru.GFX_TOP,
		side = ctru.GFX_LEFT,
		transferFlags = DISPLAY_TRANSFER_FLAGS
	)


	// load in default shaders
    sf := ctru.fopen("romfs:/vshader.shbin", "rb")
    ctru.fseek(sf, 0, ctru.SEEK_END)
    sh_size := ctru.ftell(sf)
    ctru.fseek(sf, 0, ctru.SEEK_SET)
    mbi.shader_buffer = ctru.malloc(uint(sh_size))
    ctru.fread(mbi.shader_buffer, 1, uint(sh_size), sf)
    ctru.fclose(sf)
    ctru.printf("\x1b[3;1Hsh_size: %d    ", sh_size) // expect 252

    // Parse the binary.  sh_buf must stay valid while dvlb is in use.
    mbi.dvlb = ctru.DVLB_ParseFile(cast(^u32)mbi.shader_buffer, u32(sh_size))

    // Create, link, and bind the shader program.
    // prog: ctru.shaderProgram_s
    ctru.shaderProgramInit(&mbi.prog)
    ctru.shaderProgramSetVsh(&mbi.prog, mbi.dvlb.DVLE) // dvlb.DVLE points to DVLE[0]
    c3d.BindProgram(&mbi.prog)

    // Look up the projection uniform register index.
    mbi.uloc_proj = i32(ctru.shaderInstanceGetUniformLocation(mbi.prog.vertexShader, "projection"))
    
	attr_info := c3d.GetAttrInfo()
    c3d.AttrInfo_Init(attr_info)
    c3d.AttrInfo_AddLoader(attr_info, 0, .FLOAT, 3) // v0 = position (xyz)
    c3d.AttrInfo_AddLoader(attr_info, 1, .FLOAT, 4) // v1 = colour   (rgba)


    // The GPU DMA engine requires vertex data in the 3DS linear heap.
    vbo_size := uint(MAX_BATCH_VERTICES * size_of(Vertex))
    mbi.vbo_data = ctru.linearAlloc(vbo_size)
    // ctru.memcpy(mbi.vbo_data, &vertex_list, vbo_size)

    buf_info := c3d.C3D_GetBufInfo()
    c3d.BufInfo_Init(buf_info)
    c3d.BufInfo_Add(buf_info, mbi.vbo_data, size_of(Vertex), 2, 0x10)

	
    env := c3d.C3D_GetTexEnv(0)
    c3d.TexEnvInit(env)
    c3d.TexEnvSrc(env, c3d.C3D_Both,.PRIMARY_COLOR, .PRIMARY_COLOR, .PRIMARY_COLOR)
    c3d.TexEnvFunc(env, c3d.C3D_Both, .REPLACE)

    mbi.projection.r[0] = c3d.FVec{ 0.0, 0.0, 1.0, 0.0} // Row 0 – screen-Y → GPU-X:  C(w,z,y,x) = ( 1,  0, -2/240,  0)
    mbi.projection.r[1] = c3d.FVec{ 0.0, 0.0, 0.0, -1.0} // Row 1 – screen-X → GPU-Y:  C(w,z,y,x) = ( 1,  0,  0, −2/400)
    mbi.projection.r[2] = c3d.FVec{-1.0, 1.0, 0.0, 0.0} // Row 2 – Z transform:        C(w,z,y,x) = (−1,  1,  0,  0)
    mbi.projection.r[3] = c3d.FVec{ 1.0, 0.0, 0.0, 0.0} // Row 3 – homogeneous W:      C(w,z,y,x) = ( 1,  0,  0,  0)
    r00 := transmute(u32)(mbi.projection.r[0].x)
    r01 := transmute(u32)(mbi.projection.r[0].y)

    c3d.DepthTest(false, .ALWAYS, .ALL)
    c3d.CullFace(.NONE)



	// Delta time
	timestamp.last_time = ctru.osGetTime()
}

/*Returns true if the window is running; other returns fale -> Almost always will return true*/
is_running :: proc() -> bool {
	return mbi.is_running && ctru.aptMainLoop()
}

/*Stops running the application*/
stop_running :: proc() {
	mbi.is_running = false
}

/*Returns the delta time value*/
get_delta_time :: proc() -> (dt:f64) {
	now := ctru.osGetTime() // u64, milliseconds
	dt = f64(now - timestamp.last_time) / 1000.0
	timestamp.last_time = now
	return dt}

/*Cleans up resources created by Matchbox*/
cleanup :: proc() {

    ctru.linearFree(mbi.vbo_data)
    ctru.shaderProgramFree(&mbi.prog)
    ctru.DVLB_Free(mbi.dvlb)
    ctru.free(mbi.shader_buffer)
    c3d.C3D_Fini()
    ctru.gfxExit()
    ctru.romfsExit()
	
	// log.destroy_console_logger(mbi.logger)
}
