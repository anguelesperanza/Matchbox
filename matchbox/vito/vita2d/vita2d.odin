package vita2d

// Bindings for libvita2d (vita/libvita2d in vdpm). Checked against
// %VITASDK%\arm-vita-eabi\include\vita2d.h.
//
// Functions with float parameters are bound to wrappers in bridge.c (named
// vito_vita2d_*) because Odin passes f32 in integer registers while vita2d
// expects VFP registers. From Odin they are called with ordinary f32 values.
// The remaining functions are bound directly.
//
// Not bound: the printf-style functions (vita2d_font_draw_textf, _textf_ls,
// vita2d_pgf_draw_textf, _textf_ls, vita2d_pvf_draw_textf, _textf_ls). They are
// C variadics, and the ones with a float argument cannot pass it correctly
// through Odin. Format the string in Odin and call the plain draw_text.
//
// Build requirements (see NewProjectTemplate\build.bat):
//   - compile lib\vita2d\bridge.c with the other objects
//   - link: -lvita2d -lSceDisplay_stub -lSceGxm_stub -lSceSysmodule_stub
//           -lSceCtrl_stub -lScePgf_stub -lScePvf_stub -lSceCommonDialog_stub
//           -lSceAppMgr_stub -lSceSysmem_stub -lSceLibKernel_stub
//           -lfreetype -lpng16 -ljpeg -lz -lbz2 -lm

import sce "../sce"

foreign import vita2d        "system:vita2d"
foreign import vita2d_bridge "system:vita2d_bridge"

// ---------------------------------------------------------------
// Types
// ---------------------------------------------------------------

// vita2d_texture. The fields are public in the header, but use the functions
// below to read or change them.
Texture :: struct {
    gxm_tex:   sce.GxmTexture,
    data_uid:  i32,
    palette_uid: i32,
    gxm_rtgt:  ^sce.GxmRenderTarget,
    gxm_sfc:   sce.GxmColorSurface,
    gxm_sfd:   sce.GxmDepthStencilSurface,
    depth_uid: i32,
}
#assert(size_of(Texture) == 0x64)
#assert(offset_of(Texture, gxm_rtgt) == 0x18)
#assert(offset_of(Texture, gxm_sfc) == 0x1C)
#assert(offset_of(Texture, gxm_sfd) == 0x4C)
#assert(offset_of(Texture, depth_uid) == 0x60)

// Opaque font handles.
Font :: struct {}
Pgf  :: struct {}
Pvf  :: struct {}

// vita2d_color_vertex, for DrawArray. Memory must come from PoolMalloc /
// PoolMemalign.
ColorVertex :: struct {
    x, y, z: f32,
    color:   u32,
}
#assert(size_of(ColorVertex) == 16)

// vita2d_texture_vertex, for DrawArrayTextured.
TextureVertex :: struct {
    x, y, z: f32,
    u, v:    f32,
}
#assert(size_of(TextureVertex) == 20)

// vita2d_system_pgf_config / vita2d_system_pvf_config. in_font_group is
// called with a character code and returns non-zero if the font should be
// used for it.
SystemPgfConfig :: struct {
    code:          sce.FontLanguageCode,
    in_font_group: proc "c" (c: u32) -> i32,
}
#assert(size_of(SystemPgfConfig) == 8)

SystemPvfConfig :: struct {
    code:          sce.PvfLanguageCode,
    in_font_group: proc "c" (c: u32) -> i32,
}
#assert(size_of(SystemPvfConfig) == 8)

TextureFilter :: sce.GxmTextureFilter

// RGBA8 packs a color for vita2d. Same layout as sce.Color32.
RGBA8 :: #force_inline proc "contextless" (r, g, b, a: u8) -> u32 {
    return u32(a) << 24 | u32(b) << 16 | u32(g) << 8 | u32(r)
}

@(default_calling_convention = "c")
foreign vita2d {
    // ---------------------------------------------------------------
    // Setup and frame control
    // ---------------------------------------------------------------
    @(link_name = "vita2d_init")                      Init                  :: proc() -> i32 ---
    @(link_name = "vita2d_init_advanced")             InitAdvanced          :: proc(temp_pool_size: u32) -> i32 ---
    @(link_name = "vita2d_init_advanced_with_msaa")   InitAdvancedWithMsaa  :: proc(temp_pool_size: u32, msaa: sce.GxmMultisampleMode) -> i32 ---
    @(link_name = "vita2d_fini")                      Fini                  :: proc() -> i32 ---
    @(link_name = "vita2d_wait_rendering_done")       WaitRenderingDone     :: proc() ---
    @(link_name = "vita2d_start_drawing")             StartDrawing          :: proc() ---
    // target is a render-target texture (CreateEmptyTextureRendertarget), or nil
    // for the screen. flags are SceGxmSceneFlags (sce.GXM_SCENE_*).
    @(link_name = "vita2d_start_drawing_advanced")    StartDrawingAdvanced  :: proc(target: ^Texture, flags: u32) ---
    @(link_name = "vita2d_end_drawing")               EndDrawing            :: proc() ---
    @(link_name = "vita2d_swap_buffers")              SwapBuffers           :: proc() ---
    @(link_name = "vita2d_clear_screen")              ClearScreen           :: proc() ---
    @(link_name = "vita2d_set_clear_color")           SetClearColor         :: proc(color: u32) ---
    @(link_name = "vita2d_get_clear_color")           GetClearColor         :: proc() -> u32 ---
    @(link_name = "vita2d_set_vblank_wait")           SetVblankWait         :: proc(enable: i32) ---
    @(link_name = "vita2d_common_dialog_update")      CommonDialogUpdate    :: proc() -> i32 ---
    @(link_name = "vita2d_get_current_fb")            GetCurrentFb          :: proc() -> rawptr ---
    @(link_name = "vita2d_get_context")               GetContext            :: proc() -> ^sce.GxmContext ---
    @(link_name = "vita2d_get_shader_patcher")        GetShaderPatcher      :: proc() -> ^sce.GxmShaderPatcher ---
    @(link_name = "vita2d_get_linear_indices")        GetLinearIndices      :: proc() -> [^]u16 ---

    // ---------------------------------------------------------------
    // Clipping and blending (integer arguments only)
    // ---------------------------------------------------------------
    @(link_name = "vita2d_set_region_clip")     SetRegionClip     :: proc(mode: sce.GxmRegionClipMode, x_min, y_min, x_max, y_max: u32) ---
    @(link_name = "vita2d_enable_clipping")     EnableClipping    :: proc() ---
    @(link_name = "vita2d_disable_clipping")    DisableClipping   :: proc() ---
    @(link_name = "vita2d_get_clipping_enabled") ClippingEnabled  :: proc() -> i32 ---
    @(link_name = "vita2d_set_clip_rectangle")  SetClipRectangle  :: proc(x_min, y_min, x_max, y_max: i32) ---
    @(link_name = "vita2d_get_clip_rectangle")  GetClipRectangle  :: proc(x_min, y_min, x_max, y_max: ^i32) ---
    @(link_name = "vita2d_set_blend_mode_add")  SetBlendModeAdd   :: proc(enable: i32) ---

    // ---------------------------------------------------------------
    // Temporary vertex pool. Memory from here lives until the end of the frame.
    // ---------------------------------------------------------------
    @(link_name = "vita2d_pool_malloc")         PoolMalloc        :: proc(size: u32) -> rawptr ---
    @(link_name = "vita2d_pool_memalign")       PoolMemalign      :: proc(size, alignment: u32) -> rawptr ---
    @(link_name = "vita2d_pool_free_space")     PoolFreeSpace     :: proc() -> u32 ---
    @(link_name = "vita2d_pool_reset")          PoolReset         :: proc() ---

    // ---------------------------------------------------------------
    // Raw vertex drawing. vertices must come from PoolMalloc / PoolMemalign.
    // ---------------------------------------------------------------
    @(link_name = "vita2d_draw_array")          DrawArray         :: proc(mode: sce.GxmPrimitiveType, vertices: [^]ColorVertex, count: uint) ---
    @(link_name = "vita2d_draw_array_textured") DrawArrayTextured :: proc(tex: ^Texture, mode: sce.GxmPrimitiveType, vertices: [^]TextureVertex, count: uint, color: u32) ---

    // ---------------------------------------------------------------
    // Textures (no float parameters)
    // ---------------------------------------------------------------
    @(link_name = "vita2d_texture_set_alloc_memblock_type") TextureSetAllocMemblockType :: proc(type: u32) ---
    @(link_name = "vita2d_texture_get_alloc_memblock_type") TextureAllocMemblockType    :: proc() -> u32 ---
    @(link_name = "vita2d_create_empty_texture")            CreateEmptyTexture             :: proc(w, h: u32) -> ^Texture ---
    @(link_name = "vita2d_create_empty_texture_format")     CreateEmptyTextureFormat       :: proc(w, h: u32, format: sce.GxmTextureFormat) -> ^Texture ---
    @(link_name = "vita2d_create_empty_texture_rendertarget") CreateEmptyTextureRendertarget :: proc(w, h: u32, format: sce.GxmTextureFormat) -> ^Texture ---
    @(link_name = "vita2d_load_PNG_file")       LoadPNGFile       :: proc(filename: cstring) -> ^Texture ---
    @(link_name = "vita2d_load_PNG_buffer")     LoadPNGBuffer     :: proc(buffer: rawptr) -> ^Texture ---
    @(link_name = "vita2d_load_JPEG_file")      LoadJPEGFile      :: proc(filename: cstring) -> ^Texture ---
    @(link_name = "vita2d_load_JPEG_buffer")    LoadJPEGBuffer    :: proc(buffer: rawptr, size: u32) -> ^Texture ---
    @(link_name = "vita2d_load_BMP_file")       LoadBMPFile       :: proc(filename: cstring) -> ^Texture ---
    @(link_name = "vita2d_load_BMP_buffer")     LoadBMPBuffer     :: proc(buffer: rawptr) -> ^Texture ---
    @(link_name = "vita2d_free_texture")        FreeTexture       :: proc(tex: ^Texture) ---
    @(link_name = "vita2d_texture_get_width")   TextureWidth      :: proc(tex: ^Texture) -> u32 ---
    @(link_name = "vita2d_texture_get_height")  TextureHeight     :: proc(tex: ^Texture) -> u32 ---
    @(link_name = "vita2d_texture_get_stride")  TextureStride     :: proc(tex: ^Texture) -> u32 ---
    @(link_name = "vita2d_texture_get_format")  TextureFormat     :: proc(tex: ^Texture) -> sce.GxmTextureFormat ---
    @(link_name = "vita2d_texture_get_datap")   TextureData       :: proc(tex: ^Texture) -> rawptr ---
    @(link_name = "vita2d_texture_get_palette") TexturePalette    :: proc(tex: ^Texture) -> rawptr ---
    @(link_name = "vita2d_texture_get_min_filter") TextureMinFilter :: proc(tex: ^Texture) -> TextureFilter ---
    @(link_name = "vita2d_texture_get_mag_filter") TextureMagFilter :: proc(tex: ^Texture) -> TextureFilter ---
    @(link_name = "vita2d_texture_set_filters") TextureSetFilters :: proc(tex: ^Texture, min_filter, mag_filter: TextureFilter) ---

    // ---------------------------------------------------------------
    // FreeType font text (no float parameters except the line-spaced draw,
    // which is in the bridge section below). size is in pixels.
    // ---------------------------------------------------------------
    @(link_name = "vita2d_load_font_file")      LoadFontFile      :: proc(filename: cstring) -> ^Font ---
    @(link_name = "vita2d_load_font_mem")       LoadFontMem       :: proc(buffer: rawptr, size: u32) -> ^Font ---
    @(link_name = "vita2d_free_font")           FreeFont          :: proc(font: ^Font) ---
    @(link_name = "vita2d_font_draw_text")      FontDrawText      :: proc(font: ^Font, x, y: i32, color, size: u32, text: cstring) -> i32 ---
    @(link_name = "vita2d_font_text_dimensions") FontTextDimensions :: proc(font: ^Font, size: u32, text: cstring, width, height: ^i32) ---
    @(link_name = "vita2d_font_text_width")     FontTextWidth     :: proc(font: ^Font, size: u32, text: cstring) -> i32 ---
    @(link_name = "vita2d_font_text_height")    FontTextHeight    :: proc(font: ^Font, size: u32, text: cstring) -> i32 ---

    // ---------------------------------------------------------------
    // PGF text loaders. The vita2d PGF functions are weak imports.
    // ---------------------------------------------------------------
    @(link_name = "vita2d_load_system_pgf")     LoadSystemPgf     :: proc(num_fonts: i32, configs: [^]SystemPgfConfig) -> ^Pgf ---
    @(link_name = "vita2d_load_default_pgf")    LoadDefaultPgf    :: proc() -> ^Pgf ---
    @(link_name = "vita2d_load_custom_pgf")     LoadCustomPgf     :: proc(path: cstring) -> ^Pgf ---
    @(link_name = "vita2d_free_pgf")            FreePgf           :: proc(font: ^Pgf) ---

    // ---------------------------------------------------------------
    // PVF text loaders
    // ---------------------------------------------------------------
    @(link_name = "vita2d_load_system_pvf")     LoadSystemPvf     :: proc(num_fonts: i32, configs: [^]SystemPvfConfig) -> ^Pvf ---
    @(link_name = "vita2d_load_default_pvf")    LoadDefaultPvf    :: proc() -> ^Pvf ---
    @(link_name = "vita2d_load_custom_pvf")     LoadCustomPvf     :: proc(path: cstring) -> ^Pvf ---
    @(link_name = "vita2d_free_pvf")            FreePvf           :: proc(font: ^Pvf) ---
}

// Wrappers from bridge.c. The f32 parameters travel in integer registers,
// matching the uint32_t parameters on the C side.
@(default_calling_convention = "c")
foreign vita2d_bridge {
    // ---------------------------------------------------------------
    // Primitives
    // ---------------------------------------------------------------
    // DrawPixel is a 1x1 rectangle. DrawPoint is vita2d's raw GPU point, which
    // has no point size set and renders as a larger, unstable square on real hardware.
    @(link_name = "vito_vita2d_draw_pixel")       DrawPixel      :: proc(x, y: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_point")       DrawPoint      :: proc(x, y: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_line")        DrawLine       :: proc(x0, y0, x1, y1: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_rectangle")   DrawRectangle  :: proc(x, y, w, h: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_fill_circle") DrawFillCircle :: proc(x, y, radius: f32, color: u32) ---

    // ---------------------------------------------------------------
    // Textures
    // ---------------------------------------------------------------
    @(link_name = "vito_vita2d_draw_texture")                  DrawTexture                :: proc(tex: ^Texture, x, y: f32) ---
    @(link_name = "vito_vita2d_draw_texture_rotate")           DrawTextureRotate          :: proc(tex: ^Texture, x, y, rad: f32) ---
    @(link_name = "vito_vita2d_draw_texture_rotate_hotspot")   DrawTextureRotateHotspot   :: proc(tex: ^Texture, x, y, rad, center_x, center_y: f32) ---
    @(link_name = "vito_vita2d_draw_texture_scale")            DrawTextureScale           :: proc(tex: ^Texture, x, y, x_scale, y_scale: f32) ---
    @(link_name = "vito_vita2d_draw_texture_part")             DrawTexturePart            :: proc(tex: ^Texture, x, y, tex_x, tex_y, tex_w, tex_h: f32) ---
    @(link_name = "vito_vita2d_draw_texture_part_scale")       DrawTexturePartScale       :: proc(tex: ^Texture, x, y, tex_x, tex_y, tex_w, tex_h, x_scale, y_scale: f32) ---
    @(link_name = "vito_vita2d_draw_texture_scale_rotate_hotspot") DrawTextureScaleRotateHotspot :: proc(tex: ^Texture, x, y, x_scale, y_scale, rad, center_x, center_y: f32) ---
    @(link_name = "vito_vita2d_draw_texture_scale_rotate")     DrawTextureScaleRotate     :: proc(tex: ^Texture, x, y, x_scale, y_scale, rad: f32) ---
    @(link_name = "vito_vita2d_draw_texture_part_scale_rotate") DrawTexturePartScaleRotate :: proc(tex: ^Texture, x, y, tex_x, tex_y, tex_w, tex_h, x_scale, y_scale, rad: f32) ---
    @(link_name = "vito_vita2d_draw_texture_tint")             DrawTextureTint            :: proc(tex: ^Texture, x, y: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_rotate")      DrawTextureTintRotate      :: proc(tex: ^Texture, x, y, rad: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_rotate_hotspot") DrawTextureTintRotateHotspot :: proc(tex: ^Texture, x, y, rad, center_x, center_y: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_scale")       DrawTextureTintScale       :: proc(tex: ^Texture, x, y, x_scale, y_scale: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_part")        DrawTextureTintPart        :: proc(tex: ^Texture, x, y, tex_x, tex_y, tex_w, tex_h: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_part_scale")  DrawTextureTintPartScale   :: proc(tex: ^Texture, x, y, tex_x, tex_y, tex_w, tex_h, x_scale, y_scale: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_scale_rotate_hotspot") DrawTextureTintScaleRotateHotspot :: proc(tex: ^Texture, x, y, x_scale, y_scale, rad, center_x, center_y: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_tint_scale_rotate") DrawTextureTintScaleRotate :: proc(tex: ^Texture, x, y, x_scale, y_scale, rad: f32, color: u32) ---
    @(link_name = "vito_vita2d_draw_texture_part_tint_scale_rotate") DrawTexturePartTintScaleRotate :: proc(tex: ^Texture, x, y, tex_x, tex_y, tex_w, tex_h, x_scale, y_scale, rad: f32, color: u32) ---

    // ---------------------------------------------------------------
    // FreeType font text. linespace is the extra pixels between lines.
    // ---------------------------------------------------------------
    @(link_name = "vito_vita2d_font_draw_text_ls") FontDrawTextLs :: proc(font: ^Font, x, y: i32, linespace: f32, color, size: u32, text: cstring) -> i32 ---

    // ---------------------------------------------------------------
    // PGF text. x and y are integers; scale is a float (1.0 = normal size).
    // ---------------------------------------------------------------
    @(link_name = "vito_vita2d_pgf_draw_text")       PgfDrawText       :: proc(font: ^Pgf, x, y: i32, color: u32, scale: f32, text: cstring) -> i32 ---
    @(link_name = "vito_vita2d_pgf_draw_text_ls")    PgfDrawTextLs     :: proc(font: ^Pgf, x, y: i32, linespace: f32, color: u32, scale: f32, text: cstring) -> i32 ---
    @(link_name = "vito_vita2d_pgf_text_dimensions") PgfTextDimensions :: proc(font: ^Pgf, scale: f32, text: cstring, width, height: ^i32) ---
    @(link_name = "vito_vita2d_pgf_text_width")      PgfTextWidth      :: proc(font: ^Pgf, scale: f32, text: cstring) -> i32 ---
    @(link_name = "vito_vita2d_pgf_text_height")     PgfTextHeight     :: proc(font: ^Pgf, scale: f32, text: cstring) -> i32 ---

    // ---------------------------------------------------------------
    // PVF text. x and y are integers; scale is a float (1.0 = normal size).
    // ---------------------------------------------------------------
    @(link_name = "vito_vita2d_pvf_draw_text")       PvfDrawText       :: proc(font: ^Pvf, x, y: i32, color: u32, scale: f32, text: cstring) -> i32 ---
    @(link_name = "vito_vita2d_pvf_draw_text_ls")    PvfDrawTextLs     :: proc(font: ^Pvf, x, y: i32, linespace: f32, color: u32, scale: f32, text: cstring) -> i32 ---
    @(link_name = "vito_vita2d_pvf_text_dimensions") PvfTextDimensions :: proc(font: ^Pvf, scale: f32, text: cstring, width, height: ^i32) ---
    @(link_name = "vito_vita2d_pvf_text_width")      PvfTextWidth      :: proc(font: ^Pvf, scale: f32, text: cstring) -> i32 ---
    @(link_name = "vito_vita2d_pvf_text_height")     PvfTextHeight     :: proc(font: ^Pvf, scale: f32, text: cstring) -> i32 ---

    // Not part of vita2d. Makes the font rasterise its glyphs at `scale` times
    // the normal size, so it can then be drawn with scale 1.0 and stay sharp.
    // Call it right after loading the font, before drawing with it. See
    // text.odin (DrawText) for the easy way to use it, and bridge.c for why.
    @(link_name = "vito_vita2d_pvf_set_base_scale")  PvfSetBaseScale   :: proc(font: ^Pvf, scale: f32) -> i32 ---
}
