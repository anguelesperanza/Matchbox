// Package gfx sets SceGxm up and wraps the handful of steps every program
// that draws with it needs. It is deliberately thin: the drawing itself is
// done with the sce.sceGxm* calls, using gfx.ctx.
//
//   gfx.init()                                   // context, screen buffers, depth buffer, shader patcher
//   vp := gfx.register_program(#load("shaders/color_v.gxp"))
//   fp := gfx.register_program(#load("shaders/color_f.gxp"))
//   ... gfx.create_vertex_program / gfx.create_fragment_program ...
//   for {
//       gfx.begin_frame()
//       gfx.clear({0, 0, 0, 1})
//       sce.sceGxmSetVertexProgram(gfx.ctx, ...)
//       sce.sceGxmDraw(gfx.ctx, ...)
//       gfx.end_frame()
//       gfx.swap()
//   }
//   gfx.shutdown()
//
// Things SceGxm insists on, which this package takes care of or documents:
//
//   - Shaders are precompiled .gxp files (tools/build_shaders.py). The clear
//     shaders are embedded in this package.
//   - Everything the GPU reads (vertices, indices, textures) must be in
//     memory mapped for it: gfx.alloc, not new / make.
//   - Do not free GPU memory, or overwrite vertices, while a frame that uses
//     them may still be rendering. gfx.finish() waits for the GPU.
//   - Clip space is OpenGL's: x and y from -1 to 1 with +y up, z from -1
//     (near) to 1 (far). linalg.matrix4_perspective_f32 and matrix_ortho3d_f32
//     produce matching matrices.
//   - Matrices: pass Odin's matrix memory as it is and write mul(vector,
//     matrix) in the shader. (Cg stores matrices by row, Odin by column.)
//
// Link: -lSceGxm_stub -lSceDisplay_stub -lSceCommonDialog_stub -lSceSysmem_stub -lpng16 -lz
// and compile lib/sce/bridge.c (BRIDGES=... sce) for the float-taking calls.
package gfx

import sce "../sce"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
    @(link_name = "malloc") c_malloc :: proc(size: uint) -> rawptr ---
    @(link_name = "free")   c_free   :: proc(ptr: rawptr) ---
}

WIDTH  :: sce.DISPLAY_WIDTH
HEIGHT :: sce.DISPLAY_HEIGHT
STRIDE :: 960 // in pixels; a multiple of 64
DISPLAY_BUFFER_COUNT :: 3

// Antialiasing for the screen. ._4X renders four samples per pixel and
// averages them; it costs GPU time and memory but no code changes.
Config :: struct {
    multisample: sce.GxmMultisampleMode,
}

// Which step of init failed (0 when it worked) and the SCE error it returned.
Init_Step :: enum {
    None,
    Initialize,
    Ring_Buffers,
    Context,
    Render_Target,
    Display_Buffers,
    Depth_Buffer,
    Shader_Patcher,
    Clear_Programs,
}

// The SceGxm context; pass it to every sce.sceGxm* drawing call.
ctx:         ^sce.GxmContext
patcher:     ^sce.GxmShaderPatcher
multisample: sce.GxmMultisampleMode
init_step:   Init_Step
init_error:  i32

@(private) Display_Data :: struct {
    address: rawptr,
}

@(private) render_target:   ^sce.GxmRenderTarget
@(private) display_surface: [DISPLAY_BUFFER_COUNT]sce.GxmColorSurface
@(private) display_sync:    [DISPLAY_BUFFER_COUNT]^sce.GxmSyncObject
@(private) display_data:    [DISPLAY_BUFFER_COUNT]rawptr
@(private) display_uid:     [DISPLAY_BUFFER_COUNT]sce.UID
@(private) front_index, back_index: int
@(private) depth_surface:   sce.GxmDepthStencilSurface
@(private) depth_data:      rawptr
@(private) depth_uid:       sce.UID

@(private) host_mem: rawptr
@(private) vdm_uid, vertex_ring_uid, fragment_ring_uid, fragment_usse_ring_uid: sce.UID
@(private) patcher_buffer_uid, patcher_vertex_usse_uid, patcher_fragment_usse_uid: sce.UID

@(private) clear_v_blob := #load("shaders/clear_v.gxp")
@(private) clear_f_blob := #load("shaders/clear_f.gxp")
@(private) clear_vp: ^sce.GxmVertexProgram
@(private) clear_fp: ^sce.GxmFragmentProgram        // for the screen
@(private) clear_target_fp: ^sce.GxmFragmentProgram // for offscreen targets, which are not multisampled
@(private) drawing_to_target: bool
@(private) target_width, target_height: int // of whatever is being drawn into
@(private) clear_v, clear_f: Program
@(private) clear_color_param: ^sce.GxmProgramParameter
@(private) clear_vertices: [^][2]f32
@(private) clear_indices:  [^]u16
@(private) clear_uid:      sce.UID

// ---------------------------------------------------------------
// Start-up and shutdown
// ---------------------------------------------------------------

// Sets SceGxm up for drawing to the screen. On failure, init_step and
// init_error say where and why.
init :: proc "contextless" (config: Config = {}) -> bool {
    fail :: proc "contextless" (step: Init_Step, error: i32) -> bool {
        init_step, init_error = step, error
        return false
    }
    multisample = config.multisample

    // --- the library, and the callback that shows a finished frame
    params: sce.GxmInitializeParams
    params.displayQueueMaxPendingCount  = DISPLAY_BUFFER_COUNT - 1
    params.displayQueueCallback         = display_callback
    params.displayQueueCallbackDataSize = size_of(Display_Data)
    params.parameterBufferSize          = sce.GXM_DEFAULT_PARAMETER_BUFFER_SIZE
    if r := sce.sceGxmInitialize(&params); r < 0 do return fail(.Initialize, r)

    // --- the context and the ring buffers it writes its commands into
    vdm, vertex_ring, fragment_ring, fragment_usse: rawptr
    fragment_usse_offset: u32
    vdm, vdm_uid                     = alloc(sce.GXM_DEFAULT_VDM_RING_BUFFER_SIZE)
    vertex_ring, vertex_ring_uid     = alloc(sce.GXM_DEFAULT_VERTEX_RING_BUFFER_SIZE)
    fragment_ring, fragment_ring_uid = alloc(sce.GXM_DEFAULT_FRAGMENT_RING_BUFFER_SIZE)
    fragment_usse, fragment_usse_ring_uid = alloc_fragment_usse(sce.GXM_DEFAULT_FRAGMENT_USSE_RING_BUFFER_SIZE, &fragment_usse_offset)
    if vdm == nil || vertex_ring == nil || fragment_ring == nil || fragment_usse == nil {
        return fail(.Ring_Buffers, last_alloc_error)
    }

    host_mem = c_malloc(sce.GXM_MINIMUM_CONTEXT_HOST_MEM_SIZE)
    context_params: sce.GxmContextParams
    context_params.hostMem                       = host_mem
    context_params.hostMemSize                   = sce.GXM_MINIMUM_CONTEXT_HOST_MEM_SIZE
    context_params.vdmRingBufferMem              = vdm
    context_params.vdmRingBufferMemSize          = sce.GXM_DEFAULT_VDM_RING_BUFFER_SIZE
    context_params.vertexRingBufferMem           = vertex_ring
    context_params.vertexRingBufferMemSize       = sce.GXM_DEFAULT_VERTEX_RING_BUFFER_SIZE
    context_params.fragmentRingBufferMem         = fragment_ring
    context_params.fragmentRingBufferMemSize     = sce.GXM_DEFAULT_FRAGMENT_RING_BUFFER_SIZE
    context_params.fragmentUsseRingBufferMem     = fragment_usse
    context_params.fragmentUsseRingBufferMemSize = sce.GXM_DEFAULT_FRAGMENT_USSE_RING_BUFFER_SIZE
    context_params.fragmentUsseRingBufferOffset  = fragment_usse_offset
    if r := sce.sceGxmCreateContext(&context_params, &ctx); r < 0 do return fail(.Context, r)

    // --- the screen as a render target
    target_params: sce.GxmRenderTargetParams
    target_params.width           = WIDTH
    target_params.height          = HEIGHT
    target_params.scenesPerFrame  = 1
    target_params.multisampleMode = u16(multisample)
    target_params.driverMemBlock  = -1
    if r := sce.sceGxmCreateRenderTarget(&target_params, &render_target); r < 0 do return fail(.Render_Target, r)

    // --- the buffers the screen shows, each with a sync object so the GPU
    //     and the display never use the same one at the same time
    for i in 0 ..< DISPLAY_BUFFER_COUNT {
        display_data[i], display_uid[i] = alloc(4 * STRIDE * HEIGHT, sce.KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW,
                                                sce.GXM_MEMORY_ATTRIB_READ | sce.GXM_MEMORY_ATTRIB_WRITE)
        if display_data[i] == nil do return fail(.Display_Buffers, last_alloc_error)
        pixels := ([^]u32)(display_data[i])
        for p in 0 ..< STRIDE * HEIGHT do pixels[p] = 0xFF000000
        scale := sce.GxmColorSurfaceScaleMode.NONE if multisample == .NONE else sce.GxmColorSurfaceScaleMode.MSAA_DOWNSCALE
        r := sce.sceGxmColorSurfaceInit(&display_surface[i], .U8U8U8U8_ABGR, .LINEAR, scale, ._32BIT,
                                        WIDTH, HEIGHT, STRIDE, display_data[i])
        if r < 0 do return fail(.Display_Buffers, r)
        if r = sce.sceGxmSyncObjectCreate(&display_sync[i]); r < 0 do return fail(.Display_Buffers, r)
    }
    front_index, back_index = 0, 0 // swap() moves back_index on before the second frame

    // --- depth and stencil for the screen
    ok: bool
    depth_surface, depth_data, depth_uid, ok = create_depth_surface(WIDTH, HEIGHT, multisample)
    if !ok do return fail(.Depth_Buffer, last_alloc_error)

    // --- the shader patcher, which turns .gxp programs into ones the GPU can run
    PATCHER_BUFFER_SIZE :: 64 * 1024
    PATCHER_USSE_SIZE   :: 64 * 1024
    patcher_params: sce.GxmShaderPatcherParams
    patcher_params.hostAllocCallback = patcher_host_alloc
    patcher_params.hostFreeCallback  = patcher_host_free
    patcher_params.bufferMemSize       = PATCHER_BUFFER_SIZE
    patcher_params.vertexUsseMemSize   = PATCHER_USSE_SIZE
    patcher_params.fragmentUsseMemSize = PATCHER_USSE_SIZE
    patcher_params.bufferMem, patcher_buffer_uid = alloc(PATCHER_BUFFER_SIZE, sce.KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE,
                                                         sce.GXM_MEMORY_ATTRIB_READ | sce.GXM_MEMORY_ATTRIB_WRITE)
    patcher_params.vertexUsseMem, patcher_vertex_usse_uid     = alloc_vertex_usse(PATCHER_USSE_SIZE, &patcher_params.vertexUsseOffset)
    patcher_params.fragmentUsseMem, patcher_fragment_usse_uid = alloc_fragment_usse(PATCHER_USSE_SIZE, &patcher_params.fragmentUsseOffset)
    if patcher_params.bufferMem == nil || patcher_params.vertexUsseMem == nil || patcher_params.fragmentUsseMem == nil {
        return fail(.Shader_Patcher, last_alloc_error)
    }
    if r := sce.sceGxmShaderPatcherCreate(&patcher_params, &patcher); r < 0 do return fail(.Shader_Patcher, r)

    // --- the programs clear() draws with
    clear_v, ok = register_program(clear_v_blob)
    if !ok do return fail(.Clear_Programs, last_program_error)
    clear_f, ok = register_program(clear_f_blob)
    if !ok do return fail(.Clear_Programs, last_program_error)
    attributes := [?]sce.GxmVertexAttribute{attribute(clear_v, "aPosition", 0, sce.GXM_ATTRIBUTE_FORMAT_F32, 2)}
    clear_vp = create_vertex_program(clear_v, attributes[:], size_of([2]f32))
    clear_fp = create_fragment_program(clear_f, clear_v)
    clear_target_fp = create_fragment_program(clear_f, clear_v, .None, sce.GxmMultisampleMode.NONE)
    if clear_vp == nil || clear_fp == nil || clear_target_fp == nil do return fail(.Clear_Programs, last_program_error)
    clear_color_param = parameter(clear_f, "uClearColor")

    memory: rawptr
    memory, clear_uid = alloc(3 * size_of([2]f32) + 3 * size_of(u16))
    if memory == nil do return fail(.Clear_Programs, last_alloc_error)
    clear_vertices = ([^][2]f32)(memory)
    clear_indices  = ([^]u16)(uintptr(memory) + 3 * size_of([2]f32))
    clear_vertices[0] = {-1, -1}
    clear_vertices[1] = { 3, -1}
    clear_vertices[2] = {-1,  3}
    clear_indices[0], clear_indices[1], clear_indices[2] = 0, 1, 2

    init_step, init_error = .None, 0
    return true
}

// Waits for the GPU and the display, then releases everything init made.
// Programs, textures and memory made by the caller should be released first.
shutdown :: proc "contextless" () {
    if ctx == nil do return
    sce.sceGxmFinish(ctx)
    sce.sceGxmDisplayQueueFinish()

    if clear_target_fp != nil do sce.sceGxmShaderPatcherReleaseFragmentProgram(patcher, clear_target_fp)
    if clear_fp != nil do sce.sceGxmShaderPatcherReleaseFragmentProgram(patcher, clear_fp)
    if clear_vp != nil do sce.sceGxmShaderPatcherReleaseVertexProgram(patcher, clear_vp)
    unregister_program(&clear_f)
    unregister_program(&clear_v)
    free(clear_uid)

    sce.sceGxmShaderPatcherDestroy(patcher)
    free_fragment_usse(patcher_fragment_usse_uid)
    free_vertex_usse(patcher_vertex_usse_uid)
    free(patcher_buffer_uid)

    free(depth_uid)
    for i in 0 ..< DISPLAY_BUFFER_COUNT {
        sce.sceGxmSyncObjectDestroy(display_sync[i])
        free(display_uid[i])
    }
    sce.sceGxmDestroyRenderTarget(render_target)
    sce.sceGxmDestroyContext(ctx)
    free_fragment_usse(fragment_usse_ring_uid)
    free(fragment_ring_uid)
    free(vertex_ring_uid)
    free(vdm_uid)
    c_free(host_mem)
    sce.sceGxmTerminate()
    ctx, patcher = nil, nil
}

// ---------------------------------------------------------------
// Frames
// ---------------------------------------------------------------

// Starts drawing to the screen.
begin_frame :: proc "contextless" () -> i32 {
    r := sce.sceGxmBeginScene(ctx, 0, render_target, nil, nil, display_sync[back_index],
                              &display_surface[back_index], &depth_surface)
    drawing_to_target = false
    target_width, target_height = WIDTH, HEIGHT
    set_viewport(WIDTH, HEIGHT)
    return r
}

// Maps clip space onto a target of the given size in pixels: x and y from -1
// to 1 across it with +y up, z from -1 (near) to 1 (far). begin_frame and
// begin_target call this; call it again to draw into part of the target.
set_viewport :: proc "contextless" (width, height: int, x: int = 0, y: int = 0) {
    half_width, half_height := f32(width) * 0.5, f32(height) * 0.5
    sce.sceGxmSetViewportEnable(ctx, .ENABLED)
    sce.sceGxmSetViewport(ctx, f32(x) + half_width, half_width, f32(y) + half_height, -half_height, 0.5, 0.5)
}

// Ends the scene started by begin_frame or begin_target.
end_frame :: proc "contextless" () -> i32 {
    return sce.sceGxmEndScene(ctx, nil, nil)
}

// Queues the finished frame for display. This waits when the display is more
// than two frames behind, which is what ties the loop to 60 frames a second.
swap :: proc "contextless" () {
    sce.sceGxmPadHeartbeat(&display_surface[back_index], display_sync[back_index])
    data := Display_Data{address = display_data[back_index]}
    sce.sceGxmDisplayQueueAddEntry(display_sync[front_index], display_sync[back_index], &data)
    front_index = back_index
    back_index = (back_index + 1) % DISPLAY_BUFFER_COUNT
    draw2d_next_frame()
}

// Waits until the GPU has finished everything it was given. Call before
// freeing or rewriting memory that a frame used.
finish :: proc "contextless" () {
    sce.sceGxmFinish(ctx)
}

// Fills the current target with one colour (r, g, b, a from 0 to 1). Depth
// and stencil start every scene already reset, so this does not touch them.
// It leaves the depth test at LESS_EQUAL with writes on, culling off.
clear :: proc "contextless" (color: [4]f32) {
    color := color
    sce.sceGxmSetVertexProgram(ctx, clear_vp)
    sce.sceGxmSetFragmentProgram(ctx, clear_target_fp if drawing_to_target else clear_fp)
    buffer: rawptr
    sce.sceGxmReserveFragmentDefaultUniformBuffer(ctx, &buffer)
    sce.sceGxmSetUniformDataF(buffer, clear_color_param, 0, 4, &color[0])

    sce.sceGxmSetCullMode(ctx, .NONE)
    sce.sceGxmSetFrontDepthFunc(ctx, .ALWAYS)
    sce.sceGxmSetFrontDepthWriteEnable(ctx, .DISABLED)
    sce.sceGxmSetVertexStream(ctx, 0, clear_vertices)
    sce.sceGxmDraw(ctx, .TRIANGLES, .U16, clear_indices, 3)
    sce.sceGxmSetFrontDepthFunc(ctx, .LESS_EQUAL)
    sce.sceGxmSetFrontDepthWriteEnable(ctx, .ENABLED)
}

// Lets an open system dialog (lib/vito/dialog.odin) draw over the frame.
// Call between end_frame and swap.
common_dialog_update :: proc "contextless" () -> i32 {
    param: sce.CommonDialogUpdateParam
    param.renderTarget.colorFormat      = .U8U8U8U8_ABGR
    param.renderTarget.surfaceType      = .LINEAR
    param.renderTarget.width            = WIDTH
    param.renderTarget.height           = HEIGHT
    param.renderTarget.strideInPixels   = STRIDE
    param.renderTarget.colorSurfaceData = display_data[back_index]
    param.renderTarget.depthSurfaceData = depth_data
    param.displaySyncObject             = display_sync[back_index]
    return sce.sceCommonDialogUpdate(&param)
}

@(private)
display_callback :: proc "c" (callback_data: rawptr) {
    data := (^Display_Data)(callback_data)
    frame: sce.DisplayFrameBuf
    frame.size        = size_of(sce.DisplayFrameBuf)
    frame.base        = data.address
    frame.pitch       = STRIDE
    frame.pixelformat = sce.DISPLAY_PIXELFORMAT_A8B8G8R8
    frame.width       = WIDTH
    frame.height      = HEIGHT
    sce.sceDisplaySetFrameBuf(&frame, .NEXTFRAME)
    sce.sceDisplayWaitVblankStart()
}

// ---------------------------------------------------------------
// GPU memory
// ---------------------------------------------------------------

// The SCE error of the last allocation that failed.
last_alloc_error: i32

// Allocates memory the GPU can read: for vertices, indices and textures.
// Returns nil on failure. The block is rounded up to 4 KiB, or to 256 KiB for
// CDRAM (video memory, sce.KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW), so pack small
// things together rather than allocating each one.
alloc :: proc "contextless" (size: uint, type: sce.KernelMemBlockType = sce.KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE,
                             attrib: sce.GxmMemoryAttribFlags = sce.GXM_MEMORY_ATTRIB_READ) -> (base: rawptr, uid: sce.UID) {
    aligned := block_size(size, type)
    uid = sce.sceKernelAllocMemBlock("vito_gfx", type, aligned, nil)
    if uid < 0 {
        last_alloc_error = uid
        return nil, -1
    }
    if r := sce.sceKernelGetMemBlockBase(uid, &base); r < 0 {
        last_alloc_error = r
        sce.sceKernelFreeMemBlock(uid)
        return nil, -1
    }
    if r := sce.sceGxmMapMemory(base, aligned, attrib); r < 0 {
        last_alloc_error = r
        sce.sceKernelFreeMemBlock(uid)
        return nil, -1
    }
    return base, uid
}

// Releases a block from alloc. The GPU must be done with it (see finish).
free :: proc "contextless" (uid: sce.UID) {
    base: rawptr
    if uid < 0 || sce.sceKernelGetMemBlockBase(uid, &base) < 0 do return
    sce.sceGxmUnmapMemory(base)
    sce.sceKernelFreeMemBlock(uid)
}

@(private)
block_size :: proc "contextless" (size: uint, type: sce.KernelMemBlockType) -> sce.Size {
    alignment := uint(sce.CDRAM_ALIGNMENT) if type == sce.KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW else uint(4096)
    return sce.Size((max(size, 1) + alignment - 1) &~ (alignment - 1))
}

// Memory for shader code, which is mapped differently from data.
@(private)
alloc_vertex_usse :: proc "contextless" (size: uint, offset: ^u32) -> (base: rawptr, uid: sce.UID) {
    return alloc_usse(size, offset, true)
}

@(private)
alloc_fragment_usse :: proc "contextless" (size: uint, offset: ^u32) -> (base: rawptr, uid: sce.UID) {
    return alloc_usse(size, offset, false)
}

@(private)
alloc_usse :: proc "contextless" (size: uint, offset: ^u32, vertex: bool) -> (base: rawptr, uid: sce.UID) {
    aligned := block_size(size, sce.KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE)
    uid = sce.sceKernelAllocMemBlock("vito_gfx_usse", sce.KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE, aligned, nil)
    if uid < 0 {
        last_alloc_error = uid
        return nil, -1
    }
    r := sce.sceKernelGetMemBlockBase(uid, &base)
    if r >= 0 {
        r = sce.sceGxmMapVertexUsseMemory(base, aligned, offset) if vertex else sce.sceGxmMapFragmentUsseMemory(base, aligned, offset)
    }
    if r < 0 {
        last_alloc_error = r
        sce.sceKernelFreeMemBlock(uid)
        return nil, -1
    }
    return base, uid
}

@(private)
free_vertex_usse :: proc "contextless" (uid: sce.UID) {
    base: rawptr
    if uid < 0 || sce.sceKernelGetMemBlockBase(uid, &base) < 0 do return
    sce.sceGxmUnmapVertexUsseMemory(base)
    sce.sceKernelFreeMemBlock(uid)
}

@(private)
free_fragment_usse :: proc "contextless" (uid: sce.UID) {
    base: rawptr
    if uid < 0 || sce.sceKernelGetMemBlockBase(uid, &base) < 0 do return
    sce.sceGxmUnmapFragmentUsseMemory(base)
    sce.sceKernelFreeMemBlock(uid)
}

@(private)
patcher_host_alloc :: proc "c" (user_data: rawptr, size: sce.Size) -> rawptr {
    return c_malloc(uint(size))
}

@(private)
patcher_host_free :: proc "c" (user_data: rawptr, mem: rawptr) {
    c_free(mem)
}

// ---------------------------------------------------------------
// Shader programs
// ---------------------------------------------------------------

// A .gxp program registered with the shader patcher.
Program :: struct {
    id:      sce.GxmShaderPatcherId,
    program: ^sce.GxmProgram,
    copy:    rawptr,
}

// The SCE error of the last program call that failed.
last_program_error: i32

// Registers a compiled shader (the bytes of a .gxp file, for example from
// #load). The bytes are copied, so the slice does not have to stay alive.
register_program :: proc "contextless" (gxp: []u8) -> (program: Program, ok: bool) {
    program.copy = c_malloc(uint(len(gxp)))
    if program.copy == nil do return {}, false
    copy(([^]u8)(program.copy)[:len(gxp)], gxp)

    header := (^sce.GxmProgram)(program.copy)
    r := sce.sceGxmProgramCheck(header)
    if r >= 0 do r = sce.sceGxmShaderPatcherRegisterProgram(patcher, header, &program.id)
    if r < 0 {
        last_program_error = r
        c_free(program.copy)
        return {}, false
    }
    program.program = sce.sceGxmShaderPatcherGetProgramFromId(program.id)
    return program, true
}

unregister_program :: proc "contextless" (program: ^Program) {
    if program.id == nil do return
    sce.sceGxmShaderPatcherUnregisterProgram(patcher, program.id)
    c_free(program.copy)
    program^ = {}
}

// Looks a shader parameter up by its name in the source: a uniform (for
// sce.sceGxmSetUniformDataF), an attribute, or a sampler. nil if the program
// has none by that name; the compiler removes parameters that are not used.
parameter :: proc "contextless" (program: Program, name: cstring) -> ^sce.GxmProgramParameter {
    return sce.sceGxmProgramFindParameterByName(program.program, name)
}

// The texture unit a sampler parameter reads from, for
// sce.sceGxmSetFragmentTexture. 0 if the parameter does not exist.
texture_unit :: proc "contextless" (program: Program, name: cstring) -> u32 {
    p := parameter(program, name)
    return sce.sceGxmProgramParameterGetResourceIndex(p) if p != nil else 0
}

// Describes where one vertex shader input comes from in the vertex data:
// offset is its position inside a vertex in bytes, format one of
// sce.GXM_ATTRIBUTE_FORMAT_*, count the number of components (3 for float3).
attribute :: proc "contextless" (program: Program, name: cstring, offset: u16, format: u8, count: u8, stream: u16 = 0) -> sce.GxmVertexAttribute {
    p := parameter(program, name)
    return {
        streamIndex    = stream,
        offset         = offset,
        format         = format,
        componentCount = count,
        regIndex       = u16(sce.sceGxmProgramParameterGetResourceIndex(p)) if p != nil else 0,
    }
}

// Makes a vertex program for one layout of vertex data. stride is the size
// of one vertex in bytes. Returns nil on failure (see last_program_error).
create_vertex_program :: proc "contextless" (program: Program, attributes: []sce.GxmVertexAttribute, stride: u16,
                                             index_source: u16 = sce.GXM_INDEX_SOURCE_INDEX_16BIT) -> ^sce.GxmVertexProgram {
    stream := sce.GxmVertexStream{stride = stride, indexSource = index_source}
    result: ^sce.GxmVertexProgram
    r := sce.sceGxmShaderPatcherCreateVertexProgram(patcher, program.id, raw_data(attributes), u32(len(attributes)), &stream, 1, &result)
    if r < 0 {
        last_program_error = r
        return nil
    }
    return result
}

// The same for vertex data that comes from more than one stream, for example
// one stream of vertices and one of per-instance values
// (indexSource = sce.GXM_INDEX_SOURCE_INSTANCE_16BIT, drawn with
// sce.sceGxmDrawInstanced). Each attribute names its stream.
create_vertex_program_streams :: proc "contextless" (program: Program, attributes: []sce.GxmVertexAttribute,
                                                     streams: []sce.GxmVertexStream) -> ^sce.GxmVertexProgram {
    result: ^sce.GxmVertexProgram
    r := sce.sceGxmShaderPatcherCreateVertexProgram(patcher, program.id, raw_data(attributes), u32(len(attributes)),
                                                    raw_data(streams), u32(len(streams)), &result)
    if r < 0 {
        last_program_error = r
        return nil
    }
    return result
}

Blend :: enum {
    None,     // the new pixel replaces the old one
    Alpha,    // mixed by the new pixel's alpha
    Additive, // added to the old pixel
}

// Makes a fragment program. It is tied to the vertex program it is used
// with, to a blend mode, and to the multisample mode of the target it draws
// to (the screen's by default; pass the target's for an offscreen one).
create_fragment_program :: proc "contextless" (program: Program, vertex: Program, blend := Blend.None,
                                               target_multisample: Maybe(sce.GxmMultisampleMode) = nil) -> ^sce.GxmFragmentProgram {
    info: sce.GxmBlendInfo
    info.colorMask = sce.GXM_COLOR_MASK_ALL
    info.colorFunc = sce.GXM_BLEND_FUNC_ADD
    info.alphaFunc = sce.GXM_BLEND_FUNC_ADD
    switch blend {
    case .None:
    case .Alpha:
        info.colorSrc = sce.GXM_BLEND_FACTOR_SRC_ALPHA
        info.colorDst = sce.GXM_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
        info.alphaSrc = sce.GXM_BLEND_FACTOR_ONE
        info.alphaDst = sce.GXM_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
    case .Additive:
        info.colorSrc = sce.GXM_BLEND_FACTOR_SRC_ALPHA
        info.colorDst = sce.GXM_BLEND_FACTOR_ONE
        info.alphaSrc = sce.GXM_BLEND_FACTOR_ONE
        info.alphaDst = sce.GXM_BLEND_FACTOR_ONE
    }
    return create_fragment_program_blend(program, vertex, nil if blend == .None else &info, target_multisample)
}

// A fragment program with a blend setup of your own: any combination of
// sce.GXM_BLEND_FUNC_* and sce.GXM_BLEND_FACTOR_*, and a colour mask
// (sce.GXM_COLOR_MASK_NONE draws to depth and stencil only). nil is no
// blending, all channels written.
create_fragment_program_blend :: proc "contextless" (program: Program, vertex: Program, info: ^sce.GxmBlendInfo,
                                                     target_multisample: Maybe(sce.GxmMultisampleMode) = nil) -> ^sce.GxmFragmentProgram {
    result: ^sce.GxmFragmentProgram
    r := sce.sceGxmShaderPatcherCreateFragmentProgram(patcher, program.id, .UCHAR4, target_multisample.? or_else multisample,
                                                      info, vertex.program, &result)
    if r < 0 {
        last_program_error = r
        return nil
    }
    return result
}

// Selects a vertex and fragment program and returns the two buffers their
// uniforms are written into with sce.sceGxmSetUniformDataF. The buffers are
// valid for the draw calls that follow, until the programs change.
use_programs :: proc "contextless" (vertex: ^sce.GxmVertexProgram, fragment: ^sce.GxmFragmentProgram) -> (vertex_uniforms, fragment_uniforms: rawptr) {
    sce.sceGxmSetVertexProgram(ctx, vertex)
    sce.sceGxmSetFragmentProgram(ctx, fragment)
    sce.sceGxmReserveVertexDefaultUniformBuffer(ctx, &vertex_uniforms)
    sce.sceGxmReserveFragmentDefaultUniformBuffer(ctx, &fragment_uniforms)
    return
}

// Writes a float uniform: a matrix (16 values), a vector, or one float.
set_uniform :: proc "contextless" (buffer: rawptr, param: ^sce.GxmProgramParameter, values: []f32) {
    if buffer == nil || param == nil || len(values) == 0 do return
    sce.sceGxmSetUniformDataF(buffer, param, 0, u32(len(values)), raw_data(values))
}

set_uniform_matrix :: proc "contextless" (buffer: rawptr, param: ^sce.GxmProgramParameter, m: ^matrix[4, 4]f32) {
    if buffer == nil || param == nil do return
    sce.sceGxmSetUniformDataF(buffer, param, 0, 16, &m[0, 0])
}

// ---------------------------------------------------------------
// Textures
// ---------------------------------------------------------------

Texture :: struct {
    texture: sce.GxmTexture,
    pixels:  [^]u32, // 0xAABBGGRR, `stride` pixels per row
    width:   int,
    height:  int,
    stride:  int,
    uid:     sce.UID,
}

// Makes an empty 32-bit texture in video memory. Write its pixels through
// texture.pixels (row y starts at y * texture.stride). Rows are padded to a
// multiple of 8 pixels, which is what a linear texture requires.
create_texture :: proc "contextless" (width, height: int, filter := sce.GxmTextureFilter.LINEAR,
                                      address := sce.GxmTextureAddrMode.REPEAT) -> (texture: Texture, ok: bool) {
    texture.width, texture.height = width, height
    texture.stride = (width + 7) &~ 7
    memory: rawptr
    memory, texture.uid = alloc(uint(4 * texture.stride * height), sce.KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW,
                                sce.GXM_MEMORY_ATTRIB_READ | sce.GXM_MEMORY_ATTRIB_WRITE)
    if memory == nil do return {}, false
    texture.pixels = ([^]u32)(memory)

    r := sce.sceGxmTextureInitLinear(&texture.texture, memory, .U8U8U8U8_ABGR, u32(width), u32(height), 0)
    if r < 0 {
        last_alloc_error = r
        free(texture.uid)
        return {}, false
    }
    sce.sceGxmTextureSetMinFilter(&texture.texture, filter)
    sce.sceGxmTextureSetMagFilter(&texture.texture, filter)
    sce.sceGxmTextureSetUAddrMode(&texture.texture, address)
    sce.sceGxmTextureSetVAddrMode(&texture.texture, address)
    return texture, true
}

Texture_Layout :: enum {
    Linear,   // rows one after another
    Swizzled, // Morton order (see swizzle); needed for mipmaps and compressed formats
}

// Makes a texture of any format from `size` bytes of video memory that the
// caller fills in through texture.pixels (cast it for formats that are not
// 32-bit). For a swizzled texture width and height must be powers of two,
// and mip levels follow each other in memory, largest first; mip_count
// includes the full-size level. Mipmaps are only used once
// sce.sceGxmTextureSetMipFilter(&texture.texture, .ENABLED) is called.
create_texture_format :: proc "contextless" (width, height: int, format: sce.GxmTextureFormat, size: int,
                                             layout := Texture_Layout.Linear, mip_count := 1,
                                             filter := sce.GxmTextureFilter.LINEAR,
                                             address := sce.GxmTextureAddrMode.REPEAT) -> (texture: Texture, ok: bool) {
    texture.width, texture.height, texture.stride = width, height, width
    memory: rawptr
    memory, texture.uid = alloc(uint(size), sce.KERNEL_MEMBLOCK_TYPE_USER_CDRAM_RW,
                                sce.GXM_MEMORY_ATTRIB_READ | sce.GXM_MEMORY_ATTRIB_WRITE)
    if memory == nil do return {}, false
    texture.pixels = ([^]u32)(memory)

    r: i32
    switch layout {
    case .Linear:   r = sce.sceGxmTextureInitLinear(&texture.texture, memory, format, u32(width), u32(height), u32(mip_count))
    case .Swizzled: r = sce.sceGxmTextureInitSwizzled(&texture.texture, memory, format, u32(width), u32(height), u32(mip_count))
    }
    if r < 0 {
        last_alloc_error = r
        free(texture.uid)
        return {}, false
    }
    sce.sceGxmTextureSetMinFilter(&texture.texture, filter)
    sce.sceGxmTextureSetMagFilter(&texture.texture, filter)
    sce.sceGxmTextureSetUAddrMode(&texture.texture, address)
    sce.sceGxmTextureSetVAddrMode(&texture.texture, address)
    return texture, true
}

// Where the pixel (or, in a block-compressed texture, the block) at x, y sits
// in a square swizzled texture: the bits of x and y interleaved, y lowest.
swizzle :: proc "contextless" (x, y: u32) -> u32 {
    spread :: proc "contextless" (v: u32) -> u32 {
        v := v & 0xFFFF
        v = (v | v << 8) & 0x00FF00FF
        v = (v | v << 4) & 0x0F0F0F0F
        v = (v | v << 2) & 0x33333333
        v = (v | v << 1) & 0x55555555
        return v
    }
    return spread(x) << 1 | spread(y)
}

destroy_texture :: proc "contextless" (texture: ^Texture) {
    free(texture.uid)
    texture^ = {}
}

// ---------------------------------------------------------------
// Drawing into a texture
// ---------------------------------------------------------------

// A texture that can be drawn into, with its own depth buffer.
Target :: struct {
    color:         Texture,
    surface:       sce.GxmColorSurface,
    depth:         sce.GxmDepthStencilSurface,
    depth_uid:     sce.UID,
    render_target: ^sce.GxmRenderTarget,
}

// Makes a render target of the given size (not multisampled). Fragment
// programs used with it must be created with target_multisample = .NONE.
create_target :: proc "contextless" (width, height: int) -> (target: Target, ok: bool) {
    target.color = create_texture(width, height, .LINEAR, .CLAMP) or_return
    r := sce.sceGxmColorSurfaceInit(&target.surface, .U8U8U8U8_ABGR, .LINEAR, .NONE, ._32BIT,
                                    u32(width), u32(height), u32(target.color.stride), target.color.pixels)
    if r < 0 {
        last_alloc_error = r
        destroy_texture(&target.color)
        return {}, false
    }
    depth_ok: bool
    target.depth, _, target.depth_uid, depth_ok = create_depth_surface(width, height, .NONE)
    if !depth_ok {
        destroy_texture(&target.color)
        return {}, false
    }
    params: sce.GxmRenderTargetParams
    params.width           = u16(width)
    params.height          = u16(height)
    params.scenesPerFrame  = 1
    params.multisampleMode = u16(sce.GxmMultisampleMode.NONE)
    params.driverMemBlock  = -1
    if r = sce.sceGxmCreateRenderTarget(&params, &target.render_target); r < 0 {
        last_alloc_error = r
        free(target.depth_uid)
        destroy_texture(&target.color)
        return {}, false
    }
    return target, true
}

destroy_target :: proc "contextless" (target: ^Target) {
    sce.sceGxmDestroyRenderTarget(target.render_target)
    free(target.depth_uid)
    destroy_texture(&target.color)
    target^ = {}
}

// Starts drawing into a target. End with end_frame. Scenes cannot be nested:
// draw into targets first, then begin_frame for the screen.
begin_target :: proc "contextless" (target: ^Target) -> i32 {
    r := sce.sceGxmBeginScene(ctx, 0, target.render_target, nil, nil, nil, &target.surface, &target.depth)
    drawing_to_target = true
    target_width, target_height = target.color.width, target.color.height
    set_viewport(target.color.width, target.color.height)
    return r
}

@(private)
create_depth_surface :: proc "contextless" (width, height: int, mode: sce.GxmMultisampleMode) -> (surface: sce.GxmDepthStencilSurface, data: rawptr, uid: sce.UID, ok: bool) {
    // Whole tiles, and more samples per pixel when multisampling.
    aligned_width  := (width  + sce.GXM_TILE_SIZEX - 1) &~ (sce.GXM_TILE_SIZEX - 1)
    aligned_height := (height + sce.GXM_TILE_SIZEY - 1) &~ (sce.GXM_TILE_SIZEY - 1)
    samples := aligned_width * aligned_height
    stride  := aligned_width
    #partial switch mode {
    case ._4X:
        samples *= 4
        stride  *= 2
    case ._2X:
        samples *= 2
    }
    data, uid = alloc(uint(4 * samples), sce.KERNEL_MEMBLOCK_TYPE_USER_RW_UNCACHE,
                      sce.GXM_MEMORY_ATTRIB_READ | sce.GXM_MEMORY_ATTRIB_WRITE)
    if data == nil do return {}, nil, -1, false
    r := sce.sceGxmDepthStencilSurfaceInit(&surface, .S8D24, .TILED, u32(stride), data, nil)
    if r < 0 {
        last_alloc_error = r
        free(uid)
        return {}, nil, -1, false
    }
    return surface, data, uid, true
}
