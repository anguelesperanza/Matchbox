// ABI bridge for vita2d functions that take float parameters.
//
// Odin passes f32 arguments in integer registers (r0-r3, then the stack).
// vita2d is compiled hard-float and expects them in VFP registers. Each
// wrapper here takes every float as uint32_t (integer register / stack slot,
// which both sides agree on) and converts with u2f() before calling the real
// function. Functions with no float parameters are bound directly from Odin.

#include <vita2d.h>
#include "../bridge_utils.h"

// ---------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------
// vita2d_draw_pixel draws a GXM POINTS primitive and never sets a point size.
// Vita3K draws 1 px, but real hardware drew a larger, flickering square. The
// binding's DrawPixel therefore draws a 1x1 rectangle (normal triangle path).
// The raw point version is kept as vito_vita2d_draw_point.
void vito_vita2d_draw_pixel(uint32_t x, uint32_t y, unsigned int color) {
    vita2d_draw_rectangle(u2f(x), u2f(y), 1.0f, 1.0f, color);
}

void vito_vita2d_draw_point(uint32_t x, uint32_t y, unsigned int color) {
    vita2d_draw_pixel(u2f(x), u2f(y), color);
}

void vito_vita2d_draw_line(uint32_t x0, uint32_t y0, uint32_t x1, uint32_t y1, unsigned int color) {
    vita2d_draw_line(u2f(x0), u2f(y0), u2f(x1), u2f(y1), color);
}

void vito_vita2d_draw_rectangle(uint32_t x, uint32_t y, uint32_t w, uint32_t h, unsigned int color) {
    vita2d_draw_rectangle(u2f(x), u2f(y), u2f(w), u2f(h), color);
}

void vito_vita2d_draw_fill_circle(uint32_t x, uint32_t y, uint32_t radius, unsigned int color) {
    vita2d_draw_fill_circle(u2f(x), u2f(y), u2f(radius), color);
}

// ---------------------------------------------------------------
// Textures
// ---------------------------------------------------------------
void vito_vita2d_draw_texture(const vita2d_texture *tex, uint32_t x, uint32_t y) {
    vita2d_draw_texture(tex, u2f(x), u2f(y));
}

void vito_vita2d_draw_texture_rotate(const vita2d_texture *tex, uint32_t x, uint32_t y, uint32_t rad) {
    vita2d_draw_texture_rotate(tex, u2f(x), u2f(y), u2f(rad));
}

void vito_vita2d_draw_texture_rotate_hotspot(const vita2d_texture *tex, uint32_t x, uint32_t y, uint32_t rad,
                                             uint32_t cx, uint32_t cy) {
    vita2d_draw_texture_rotate_hotspot(tex, u2f(x), u2f(y), u2f(rad), u2f(cx), u2f(cy));
}

void vito_vita2d_draw_texture_scale(const vita2d_texture *tex, uint32_t x, uint32_t y, uint32_t xs, uint32_t ys) {
    vita2d_draw_texture_scale(tex, u2f(x), u2f(y), u2f(xs), u2f(ys));
}

void vito_vita2d_draw_texture_part(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                   uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th) {
    vita2d_draw_texture_part(tex, u2f(x), u2f(y), u2f(tx), u2f(ty), u2f(tw), u2f(th));
}

void vito_vita2d_draw_texture_part_scale(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                         uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th,
                                         uint32_t xs, uint32_t ys) {
    vita2d_draw_texture_part_scale(tex, u2f(x), u2f(y), u2f(tx), u2f(ty), u2f(tw), u2f(th), u2f(xs), u2f(ys));
}

void vito_vita2d_draw_texture_scale_rotate(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                           uint32_t xs, uint32_t ys, uint32_t rad) {
    vita2d_draw_texture_scale_rotate(tex, u2f(x), u2f(y), u2f(xs), u2f(ys), u2f(rad));
}

void vito_vita2d_draw_texture_tint(const vita2d_texture *tex, uint32_t x, uint32_t y, unsigned int color) {
    vita2d_draw_texture_tint(tex, u2f(x), u2f(y), color);
}

void vito_vita2d_draw_texture_tint_rotate(const vita2d_texture *tex, uint32_t x, uint32_t y, uint32_t rad,
                                          unsigned int color) {
    vita2d_draw_texture_tint_rotate(tex, u2f(x), u2f(y), u2f(rad), color);
}

void vito_vita2d_draw_texture_tint_scale(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                         uint32_t xs, uint32_t ys, unsigned int color) {
    vita2d_draw_texture_tint_scale(tex, u2f(x), u2f(y), u2f(xs), u2f(ys), color);
}

void vito_vita2d_draw_texture_tint_scale_rotate(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                                uint32_t xs, uint32_t ys, uint32_t rad, unsigned int color) {
    vita2d_draw_texture_tint_scale_rotate(tex, u2f(x), u2f(y), u2f(xs), u2f(ys), u2f(rad), color);
}

// ---------------------------------------------------------------
// PVF (system vector font) text
// ---------------------------------------------------------------
//
// vita2d rasterises every PVF glyph once, at 10.125 pt (18 px tall), and draws
// other sizes by scaling that bitmap on the GPU. The glyph atlas minifies with
// POINT sampling, so any scale below 1.0 drops pixel rows and columns, and the
// pen position is an int, so each glyph's scaled advance is truncated and
// letters crowd together. Small text came out broken on screen.
//
// vito_vita2d_pvf_set_base_scale makes a font rasterise its glyphs at the wanted
// size instead, so it can be drawn with scale 1.0 (exact pixels, whole-pixel
// advances). vita2d has no call for this, so it reaches into vita2d_pvf. The
// two structs below mirror libvita2d/source/vita2d_pvf.c; the offsets were
// checked against the installed libvita2d.a (font list at 4, vsize at 48).
// Call it right after loading the font: glyphs already drawn stay cached at
// the old size.
#include <stddef.h>
#include <psp2/pvf.h>
#include <psp2/kernel/threadmgr.h>

typedef struct vito_pvf_font_handle {
    ScePvfFontId font_handle;
    int (*in_font_group)(unsigned int c);
    struct vito_pvf_font_handle *next;
} vito_pvf_font_handle;

typedef struct vito_pvf {
    ScePvfLibId lib_handle;
    vito_pvf_font_handle *font_handle_list;
    void *atlas;
    SceKernelLwMutexWork mutex;
    float vsize;
} vito_pvf;

_Static_assert(offsetof(vito_pvf, font_handle_list) == 4, "vita2d_pvf layout changed");
_Static_assert(offsetof(vito_pvf, vsize) == 48, "vita2d_pvf layout changed");

#define VITO_PVF_BASE_SIZE 10.125f // the size vita2d sets when it loads a font

int vito_vita2d_pvf_set_base_scale(vita2d_pvf *font, uint32_t scale) {
    vito_pvf *p = (vito_pvf *)font;
    float size = VITO_PVF_BASE_SIZE * u2f(scale);
    int err = 0;
    if (!p) return -1;
    for (vito_pvf_font_handle *h = p->font_handle_list; h; h = h->next) {
        int r = scePvfSetCharSize(h->font_handle, size, size);
        if (r < 0) err = r;
    }
    p->vsize = size; // line height used for '\n'
    return err;
}

int vito_vita2d_pvf_draw_text(vita2d_pvf *font, int x, int y, unsigned int color, uint32_t scale, const char *text) {
    return vita2d_pvf_draw_text(font, x, y, color, u2f(scale), text);
}

int vito_vita2d_pvf_text_width(vita2d_pvf *font, uint32_t scale, const char *text) {
    return vita2d_pvf_text_width(font, u2f(scale), text);
}

int vito_vita2d_pvf_text_height(vita2d_pvf *font, uint32_t scale, const char *text) {
    return vita2d_pvf_text_height(font, u2f(scale), text);
}

int vito_vita2d_pvf_draw_text_ls(vita2d_pvf *font, int x, int y, uint32_t linespace, unsigned int color,
                                 uint32_t scale, const char *text) {
    return vita2d_pvf_draw_text_ls(font, x, y, u2f(linespace), color, u2f(scale), text);
}

void vito_vita2d_pvf_text_dimensions(vita2d_pvf *font, uint32_t scale, const char *text, int *width, int *height) {
    vita2d_pvf_text_dimensions(font, u2f(scale), text, width, height);
}

// ---------------------------------------------------------------
// PGF (system font) text. The vita2d PGF functions are weak imports.
// ---------------------------------------------------------------
int vito_vita2d_pgf_draw_text(vita2d_pgf *font, int x, int y, unsigned int color, uint32_t scale, const char *text) {
    return vita2d_pgf_draw_text(font, x, y, color, u2f(scale), text);
}

int vito_vita2d_pgf_draw_text_ls(vita2d_pgf *font, int x, int y, uint32_t linespace, unsigned int color,
                                 uint32_t scale, const char *text) {
    return vita2d_pgf_draw_text_ls(font, x, y, u2f(linespace), color, u2f(scale), text);
}

void vito_vita2d_pgf_text_dimensions(vita2d_pgf *font, uint32_t scale, const char *text, int *width, int *height) {
    vita2d_pgf_text_dimensions(font, u2f(scale), text, width, height);
}

int vito_vita2d_pgf_text_width(vita2d_pgf *font, uint32_t scale, const char *text) {
    return vita2d_pgf_text_width(font, u2f(scale), text);
}

int vito_vita2d_pgf_text_height(vita2d_pgf *font, uint32_t scale, const char *text) {
    return vita2d_pgf_text_height(font, u2f(scale), text);
}

// ---------------------------------------------------------------
// FreeType font text. Only the line-spaced draw takes a float.
// ---------------------------------------------------------------
int vito_vita2d_font_draw_text_ls(vita2d_font *font, int x, int y, uint32_t linespace, unsigned int color,
                                  unsigned int size, const char *text) {
    return vita2d_font_draw_text_ls(font, x, y, u2f(linespace), color, size, text);
}

// ---------------------------------------------------------------
// Remaining texture draws
// ---------------------------------------------------------------
void vito_vita2d_draw_texture_scale_rotate_hotspot(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                                   uint32_t xs, uint32_t ys, uint32_t rad,
                                                   uint32_t cx, uint32_t cy) {
    vita2d_draw_texture_scale_rotate_hotspot(tex, u2f(x), u2f(y), u2f(xs), u2f(ys), u2f(rad), u2f(cx), u2f(cy));
}

void vito_vita2d_draw_texture_part_scale_rotate(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                                uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th,
                                                uint32_t xs, uint32_t ys, uint32_t rad) {
    vita2d_draw_texture_part_scale_rotate(tex, u2f(x), u2f(y), u2f(tx), u2f(ty), u2f(tw), u2f(th),
                                          u2f(xs), u2f(ys), u2f(rad));
}

void vito_vita2d_draw_texture_tint_rotate_hotspot(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                                  uint32_t rad, uint32_t cx, uint32_t cy, unsigned int color) {
    vita2d_draw_texture_tint_rotate_hotspot(tex, u2f(x), u2f(y), u2f(rad), u2f(cx), u2f(cy), color);
}

void vito_vita2d_draw_texture_tint_part(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                        uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th, unsigned int color) {
    vita2d_draw_texture_tint_part(tex, u2f(x), u2f(y), u2f(tx), u2f(ty), u2f(tw), u2f(th), color);
}

void vito_vita2d_draw_texture_tint_part_scale(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                              uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th,
                                              uint32_t xs, uint32_t ys, unsigned int color) {
    vita2d_draw_texture_tint_part_scale(tex, u2f(x), u2f(y), u2f(tx), u2f(ty), u2f(tw), u2f(th),
                                        u2f(xs), u2f(ys), color);
}

void vito_vita2d_draw_texture_tint_scale_rotate_hotspot(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                                        uint32_t xs, uint32_t ys, uint32_t rad,
                                                        uint32_t cx, uint32_t cy, unsigned int color) {
    vita2d_draw_texture_tint_scale_rotate_hotspot(tex, u2f(x), u2f(y), u2f(xs), u2f(ys), u2f(rad),
                                                  u2f(cx), u2f(cy), color);
}

void vito_vita2d_draw_texture_part_tint_scale_rotate(const vita2d_texture *tex, uint32_t x, uint32_t y,
                                                     uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th,
                                                     uint32_t xs, uint32_t ys, uint32_t rad, unsigned int color) {
    vita2d_draw_texture_part_tint_scale_rotate(tex, u2f(x), u2f(y), u2f(tx), u2f(ty), u2f(tw), u2f(th),
                                               u2f(xs), u2f(ys), u2f(rad), color);
}
