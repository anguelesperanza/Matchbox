package gfx

// 2D drawing on SceGxm: textured, tinted, rotated sprites and flat shapes,
// collected into batches so that a thousand sprites cost a handful of draw
// calls. Text is in text.odin and uses the same batch.
//
//   gfx.draw2d_init()                 // once, after gfx.init
//   ...
//   gfx.begin_frame()
//   gfx.clear(...)
//   ... any 3D drawing ...
//   gfx.begin_2d()
//   gfx.draw_texture(&player, 100, 200)
//   gfx.draw_rect(0, 0, 960, 40, gfx.rgba(0, 0, 0, 128))
//   gfx.draw_text(&font, 16, 30, "Score 100")
//   gfx.end_2d()
//   gfx.end_frame()
//   gfx.swap()
//
// Coordinates are pixels with the origin at the top left and +y down.
// Colours are 0xAABBGGRR (gfx.rgba builds one); a texture is multiplied by
// the colour, so WHITE draws it unchanged.
//
// Things drawn later cover things drawn earlier; there is no depth in 2D.
// Sprites that share a texture and are drawn one after another go out as one
// draw call, so draw by texture where the order allows, and put small images
// on one sheet (the src rectangle picks the part to draw).

import "core:math"
import sce "../sce"

Color :: u32 // 0xAABBGGRR
WHITE :: Color(0xFFFFFFFF)
BLACK :: Color(0xFF000000)

rgba :: #force_inline proc "contextless" (r, g, b: u8, a: u8 = 255) -> Color {
    return u32(a) << 24 | u32(b) << 16 | u32(g) << 8 | u32(r)
}

Rect :: struct {
    x, y, w, h: f32,
}

// The most quads (sprites, shapes, glyphs) one frame can hold, across every
// begin_2d of that frame. Anything beyond it is not drawn, and
// draw2d_dropped() says how many were lost.
MAX_QUADS_PER_FRAME :: 8192
// The most quads in one draw call; a longer run is split.
@(private) MAX_QUADS_PER_BATCH :: 2048

@(private) Vertex_2D :: struct {
    position: [2]f32,
    uv:       [2]f32,
    color:    Color,
}

// Two vertex buffers, used on alternate frames: the GPU may still be reading
// last frame's vertices while this frame's are being written.
@(private) quad_vertices:  [2][^]Vertex_2D
@(private) quad_uids:      [2]sce.UID
@(private) quad_indices:   [^]u16
@(private) quad_index_uid: sce.UID
@(private) quad_buffer:    int // which of the two
@(private) quad_count:     int // quads written this frame
@(private) batch_start:    int // first quad not yet sent to the GPU
@(private) batch_texture:  sce.GxmTexture // a copy, so the batch keeps no pointer to the caller's Texture
@(private) batch_pixels:   rawptr         // which texture that is; nil when the batch is empty
@(private) dropped_quads:  int
@(private) last_frame_quads, last_frame_batches, frame_batches: int

@(private) sprite_v_blob := #load("shaders/sprite_v.gxp")
@(private) sprite_f_blob := #load("shaders/sprite_f.gxp")
@(private) sprite_v, sprite_f: Program
@(private) sprite_vp: ^sce.GxmVertexProgram
// One fragment program per blend mode, for the screen and for offscreen targets.
@(private) sprite_fp: [Blend][2]^sce.GxmFragmentProgram
@(private) sprite_mvp_param: ^sce.GxmProgramParameter
@(private) sprite_texture_unit: u32
@(private) white_texture: Texture
@(private) current_blend: Blend
@(private) projection_2d: matrix[4, 4]f32
@(private) in_2d: bool

// Sets the 2D layer up. Call once after gfx.init.
draw2d_init :: proc "contextless" () -> bool {
    ok: bool
    sprite_v, ok = register_program(sprite_v_blob)
    if !ok do return false
    sprite_f, ok = register_program(sprite_f_blob)
    if !ok do return false

    attributes := [?]sce.GxmVertexAttribute{
        attribute(sprite_v, "aPosition", u16(offset_of(Vertex_2D, position)), sce.GXM_ATTRIBUTE_FORMAT_F32, 2),
        attribute(sprite_v, "aTexcoord", u16(offset_of(Vertex_2D, uv)),       sce.GXM_ATTRIBUTE_FORMAT_F32, 2),
        attribute(sprite_v, "aColor",    u16(offset_of(Vertex_2D, color)),    sce.GXM_ATTRIBUTE_FORMAT_U8N, 4),
    }
    sprite_vp = create_vertex_program(sprite_v, attributes[:], size_of(Vertex_2D))
    if sprite_vp == nil do return false
    for blend in Blend {
        sprite_fp[blend][0] = create_fragment_program(sprite_f, sprite_v, blend)
        sprite_fp[blend][1] = create_fragment_program(sprite_f, sprite_v, blend, sce.GxmMultisampleMode.NONE)
        if sprite_fp[blend][0] == nil || sprite_fp[blend][1] == nil do return false
    }
    sprite_mvp_param    = parameter(sprite_v, "uMvp")
    sprite_texture_unit = texture_unit(sprite_f, "uTexture")

    for i in 0 ..< 2 {
        memory: rawptr
        memory, quad_uids[i] = alloc(MAX_QUADS_PER_FRAME * 4 * size_of(Vertex_2D))
        if memory == nil do return false
        quad_vertices[i] = ([^]Vertex_2D)(memory)
    }
    memory: rawptr
    memory, quad_index_uid = alloc(MAX_QUADS_PER_BATCH * 6 * size_of(u16))
    if memory == nil do return false
    quad_indices = ([^]u16)(memory)
    for q in 0 ..< MAX_QUADS_PER_BATCH {
        base := u16(q * 4)
        quad_indices[q * 6 + 0] = base
        quad_indices[q * 6 + 1] = base + 1
        quad_indices[q * 6 + 2] = base + 2
        quad_indices[q * 6 + 3] = base
        quad_indices[q * 6 + 4] = base + 2
        quad_indices[q * 6 + 5] = base + 3
    }

    // Flat shapes are sprites of a plain white texture.
    white_texture, ok = create_texture(8, 8, .POINT, .CLAMP)
    if !ok do return false
    for i in 0 ..< 64 do white_texture.pixels[i] = WHITE
    return true
}

// The GPU must be idle (gfx.finish) before this is called.
draw2d_shutdown :: proc "contextless" () {
    destroy_texture(&white_texture)
    free(quad_index_uid)
    for uid in quad_uids do free(uid)
    for blend in Blend {
        for fp in sprite_fp[blend] {
            if fp != nil do sce.sceGxmShaderPatcherReleaseFragmentProgram(patcher, fp)
        }
    }
    if sprite_vp != nil do sce.sceGxmShaderPatcherReleaseVertexProgram(patcher, sprite_vp)
    unregister_program(&sprite_f)
    unregister_program(&sprite_v)
}

// Starts 2D drawing into the current target (the screen, or an offscreen
// target), in that target's pixels. The depth test is off until end_2d.
begin_2d :: proc "contextless" (blend := Blend.Alpha) {
    w, h := f32(target_width), f32(target_height)
    // Pixels to clip space: x 0..w -> -1..1, y 0..h -> 1..-1.
    projection_2d = {
        2 / w, 0,      0, -1,
        0,     -2 / h, 0,  1,
        0,     0,      1,  0,
        0,     0,      0,  1,
    }
    current_blend = blend
    batch_pixels  = nil
    batch_start   = quad_count
    in_2d = true
    sce.sceGxmSetCullMode(ctx, .NONE)
    sce.sceGxmSetFrontDepthFunc(ctx, .ALWAYS)
    sce.sceGxmSetFrontDepthWriteEnable(ctx, .DISABLED)
}

// Sends what is left to the GPU and turns the depth test back on.
end_2d :: proc "contextless" () {
    flush_2d()
    in_2d = false
    sce.sceGxmSetFrontDepthFunc(ctx, .LESS_EQUAL)
    sce.sceGxmSetFrontDepthWriteEnable(ctx, .ENABLED)
}

// Changes how what is drawn next mixes with what is already there.
set_blend :: proc "contextless" (blend: Blend) {
    if blend == current_blend do return
    flush_2d()
    current_blend = blend
}

// Quads lost since start-up because a frame went over MAX_QUADS_PER_FRAME.
draw2d_dropped :: proc "contextless" () -> int {
    return dropped_quads
}

// Quads and draw calls of the last finished frame.
draw2d_stats :: proc "contextless" () -> (quads, batches: int) {
    return last_frame_quads, last_frame_batches
}

// ---------------------------------------------------------------
// Sprites
// ---------------------------------------------------------------

// Draws a whole texture with its top left corner at x, y.
draw_texture :: proc "contextless" (texture: ^Texture, x, y: f32, color := WHITE) {
    w, h := f32(texture.width), f32(texture.height)
    push_quad(texture, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}}, {0, 0, 1, 1}, color)
}

// Draws part of a texture, with scaling, rotation and flipping.
//   src       the part of the texture to draw, in its pixels
//   dst       where: x, y is the point `origin` lands on, w, h the drawn size
//   origin    the point of the drawn rectangle that sits at dst.x, dst.y and
//             that it turns around, in drawn pixels from its top left
//             ({dst.w / 2, dst.h / 2} is the centre)
//   rotation  in radians, clockwise
draw_texture_ex :: proc "contextless" (texture: ^Texture, src: Rect, dst: Rect, origin: [2]f32 = {}, rotation: f32 = 0,
                                       color := WHITE, flip_x := false, flip_y := false) {
    u0, v0 := src.x / f32(texture.width), src.y / f32(texture.height)
    u1, v1 := (src.x + src.w) / f32(texture.width), (src.y + src.h) / f32(texture.height)
    if flip_x do u0, u1 = u1, u0
    if flip_y do v0, v1 = v1, v0

    // Corners relative to the origin, then turned, then moved into place.
    left, top := -origin.x, -origin.y
    right, bottom := dst.w - origin.x, dst.h - origin.y
    corners := [4][2]f32{{left, top}, {right, top}, {right, bottom}, {left, bottom}}
    if rotation != 0 {
        s, c := math.sin(rotation), math.cos(rotation)
        for &p in corners do p = {p.x * c - p.y * s, p.x * s + p.y * c}
    }
    for &p in corners do p += {dst.x, dst.y}
    push_quad(texture, corners, {u0, v0, u1, v1}, color)
}

// ---------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------

draw_rect :: proc "contextless" (x, y, w, h: f32, color: Color) {
    push_quad(&white_texture, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}}, {0, 0, 1, 1}, color)
}

// The outline of a rectangle, drawn inside it.
draw_rect_lines :: proc "contextless" (x, y, w, h: f32, thickness: f32, color: Color) {
    draw_rect(x, y, w, thickness, color)
    draw_rect(x, y + h - thickness, w, thickness, color)
    draw_rect(x, y + thickness, thickness, h - 2 * thickness, color)
    draw_rect(x + w - thickness, y + thickness, thickness, h - 2 * thickness, color)
}

draw_line :: proc "contextless" (x0, y0, x1, y1: f32, thickness: f32, color: Color) {
    dx, dy := x1 - x0, y1 - y0
    length := math.sqrt(dx * dx + dy * dy)
    if length == 0 do return
    // Half the thickness, at right angles to the line.
    nx, ny := -dy / length * thickness * 0.5, dx / length * thickness * 0.5
    push_quad(&white_texture, {{x0 + nx, y0 + ny}, {x1 + nx, y1 + ny}, {x1 - nx, y1 - ny}, {x0 - nx, y0 - ny}}, {0, 0, 1, 1}, color)
}

draw_triangle :: proc "contextless" (a, b, c: [2]f32, color: Color) {
    push_quad(&white_texture, {a, b, c, c}, {0, 0, 1, 1}, color)
}

draw_circle :: proc "contextless" (cx, cy, radius: f32, color: Color, segments := 32) {
    count := clamp(segments, 3, 128)
    previous := [2]f32{cx + radius, cy}
    for i in 1 ..= count {
        angle := f32(i) / f32(count) * math.TAU
        point := [2]f32{cx + math.cos(angle) * radius, cy + math.sin(angle) * radius}
        draw_triangle({cx, cy}, previous, point, color)
        previous = point
    }
}

// ---------------------------------------------------------------
// The batch
// ---------------------------------------------------------------

// Adds one quad: four corners in order around it (top left, top right,
// bottom right, bottom left for an upright one) and the texture coordinates
// of the first and third corner as {u0, v0, u1, v1}.
push_quad :: proc "contextless" (texture: ^Texture, corners: [4][2]f32, uv: [4]f32, color: Color) {
    if !in_2d do return
    if rawptr(texture.pixels) != batch_pixels || quad_count - batch_start >= MAX_QUADS_PER_BATCH {
        flush_2d()
        batch_texture = texture.texture
        batch_pixels  = texture.pixels
    }
    if quad_count >= MAX_QUADS_PER_FRAME {
        dropped_quads += 1
        return
    }
    v := quad_vertices[quad_buffer][quad_count * 4:]
    v[0] = {corners[0], {uv[0], uv[1]}, color}
    v[1] = {corners[1], {uv[2], uv[1]}, color}
    v[2] = {corners[2], {uv[2], uv[3]}, color}
    v[3] = {corners[3], {uv[0], uv[3]}, color}
    quad_count += 1
}

@(private)
flush_2d :: proc "contextless" () {
    count := quad_count - batch_start
    if count <= 0 || batch_pixels == nil {
        batch_start = quad_count
        return
    }
    vertex_uniforms, _ := use_programs(sprite_vp, sprite_fp[current_blend][1 if drawing_to_target else 0])
    set_uniform_matrix(vertex_uniforms, sprite_mvp_param, &projection_2d)
    sce.sceGxmSetFragmentTexture(ctx, sprite_texture_unit, &batch_texture)
    sce.sceGxmSetVertexStream(ctx, 0, &quad_vertices[quad_buffer][batch_start * 4])
    sce.sceGxmDraw(ctx, .TRIANGLES, .U16, quad_indices, u32(count * 6))
    batch_start = quad_count
    frame_batches += 1
}

// Called by swap: the next frame writes into the other vertex buffer.
@(private)
draw2d_next_frame :: proc "contextless" () {
    last_frame_quads, last_frame_batches = quad_count, frame_batches
    quad_buffer = 1 - quad_buffer
    quad_count, batch_start, frame_batches = 0, 0, 0
    batch_pixels = nil
}
