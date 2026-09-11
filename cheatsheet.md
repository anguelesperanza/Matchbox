# Matchbox cheatsheet

Every public procedure in the package -- 410 of them -- with its arguments
and one line on what it does.

**Generated from the source.** Regenerate rather than edit by hand: each
description is the first sentence of that procedure's own doc comment, so the way
to improve an entry here is to improve the comment it came from. Every public
procedure has one; anything showing _(no doc comment)_ is a regression.

Names are as exported. A game importing the package as `mb` writes `mb.init(...)`.
Private procedures are left out -- there are 109 of them and a game cannot call
any.

## Contents

- [Getting started](#getting-started) -- 24
- [Input](#input) -- 44
- [2D drawing](#2d-drawing) -- 60
- [Text and fonts](#text-and-fonts) -- 21
- [2D cameras](#2d-cameras) -- 4
- [UI](#ui) -- 70
- [3D cameras](#3d-cameras) -- 46
- [3D movement](#3d-movement) -- 4
- [3D drawing](#3d-drawing) -- 25
- [Models](#models) -- 11
- [Animation](#animation) -- 39
- [VRM](#vrm) -- 6
- [Render targets](#render-targets) -- 6
- [Sound](#sound) -- 3
- [Tiled maps](#tiled-maps) -- 3
- [Other](#other) -- 44

## Getting started

### `init.odin`

```odin
init :: proc(title: string, width: i32, height: i32)
```
Brings up SDL, the GPU backend and the window, and fills in the global `mbi`.

```odin
is_running :: proc() -> bool
```
True until the window is closed or the escape key is pressed.

```odin
cleanup :: proc()
```
Tears down everything init brought up.

```odin
wait_idle :: proc()
```
Blocks until the GPU has finished everything submitted so far.

```odin
load_shader :: proc(
	path: string,
	stage: sdl.GPUShaderStage,
	num_samplers: u32 = 0,
) -> ^sdl.GPUShader
```
Loads a shader off disk.

### `destroy.odin`

```odin
destroy :: proc
```
destroy ------- One name for giving anything back.

### `clock.odin`

```odin
get_frame_count :: proc() -> u64
```
How many frames poll_events has run.

```odin
get_delta_time :: proc() -> f32
```
Seconds elapsed during the previous frame.

```odin
get_time :: proc() -> f64
```
Seconds since init.

```odin
set_target_fps :: proc(fps: i32)
```
Limits the frame rate to `fps` frames per second by sleeping in poll_events.

### `display.odin`

```odin
set_window_fullscreen_mode :: proc(
	window: ^sdl.Window,
	mode: ^sdl.DisplayMode,
) -> bool
```
vendor:sdl3's own SetWindowFullscreenMode takes its mode `#by_ptr`, which Odin can only fill from an addressable DisplayMode value -- there is no way to pass it nil through that binding.

```odin
set_screen_type :: proc(type: Screen_Type)
```
Changes how the window occupies the screen -- see Screen_Type for what each value means.

```odin
get_screen_type :: proc() -> Screen_Type
```
What set_screen_type last actually managed to put the window into -- WINDOWED until a game calls it.

```odin
toggle_screen_type :: proc()
```
Steps to the next Screen_Type in the order the type declares them -- WINDOWED -> FULLSCREEN -> WINDOWED_FULLSCREEN -> WINDOWED -- the shape a single key (F11, say) wants without a game tracking the state itself.

```odin
set_logical_size :: proc(width: i32, height: i32)
```
Pins the resolution games draw against.

```odin
set_ui_scale :: proc(scale: f32)
```
Draws everything bigger without letterboxing it: the logical size becomes the window's pixels divided by `scale`, and every 2D draw, hit test and pointer position follows.

```odin
get_ui_scale :: proc() -> f32
```
The UI scale set by set_ui_scale, 1 until one is.

```odin
get_display_scale :: proc() -> f32
```
The scale the operating system draws other programs at on the window's display: 1.5 for Windows set to 150 percent, 2 on a Retina Mac.

```odin
screen_pos :: proc(pos: [2]f32) -> [2]f32
```
A world position as the shader wants it, with the camera and the letterbox applied.

```odin
screen_size :: proc(size: [2]f32) -> [2]f32
```
The camera zoom has to be applied here as well as in screen_pos.

```odin
get_screen_dims :: proc() -> [2]f32
```
The size everything 2D is measured against this frame.

### `files.odin`

```odin
read_entire_file :: proc(
	path: string,
	allocator := context.allocator) -> (data: []byte,
	err: Error,
)
```
Reads a whole file into memory.

```odin
get_pref_path :: proc(
	org: string,
	app: string,
	allocator := context.allocator,
) -> string
```
The one directory a game may write to, created if it is not there.

```odin
get_base_path :: proc(allocator := context.allocator) -> string
```
Where the program itself lives, ending with a separator.

## Input

### `input.odin`

```odin
poll_events :: proc()
```
Processes SDL events, updates input state, and calculates delta_time.

```odin
get_mouse_position :: proc() -> [2]f32
```
Mouse position in logical screen space, matching the coordinates you draw with.

```odin
get_mouse_wheel :: proc() -> [2]f32
```
How far the wheel was scrolled during this frame, zero when it was not touched.

```odin
get_mouse_delta :: proc() -> [2]f32
```
How far the pointer moved since the last `poll_events`, rather than where it is now.

```odin
set_cursor_locked :: proc(locked: bool)
```
Hides the pointer and keeps it in the window, reporting only how far it moved.

```odin
is_cursor_locked :: proc() -> bool
```
Whether the pointer is currently locked to the window.

```odin
set_cursor_shape :: proc(shape: Cursor_Shape)
```
The pointer's shape until the next frame, when it goes back to the arrow unless this is called again.

```odin
get_cursor_shape :: proc() -> Cursor_Shape
```
The shape the pointer is showing.

```odin
set_escape_key :: proc(key:sdl.Scancode)
```
Which key closes the window, or `.UNKNOWN` for none.

```odin
is_key_pressed :: proc(key:sdl.Scancode) -> bool
```
True only on the frame the key went down.

```odin
is_key_held :: proc(key:sdl.Scancode) -> bool
```
True every frame the key is down, including the first.

```odin
is_key_released :: proc(key:sdl.Scancode) -> bool
```
True only on the frame the key came back up.

```odin
is_key_repeated :: proc(key:sdl.Scancode) -> bool
```
Whether the key fired this frame, counting auto-repeat while it is held.

```odin
begin_text_input :: proc()
```
Starts accepting typed text, and returns it from get_text_input.

```odin
end_text_input :: proc()
```
Stops accepting typing, and takes down the on-screen keyboard a phone put up.

```odin
is_text_input_open :: proc() -> bool
```
Whether typing is being accepted.

```odin
get_text_input :: proc() -> string
```
What was typed this frame, as utf-8, empty when nothing was.

```odin
get_clipboard_text :: proc(allocator := context.allocator) -> string
```
The clipboard's contents, or "" when it holds no text.

```odin
is_mouse_pressed :: proc(button: sdl.MouseButtonFlag) -> bool
```
True only on the frame the button went down.

```odin
is_mouse_held :: proc(button: sdl.MouseButtonFlag) -> bool
```
True every frame the button is down.

```odin
is_mouse_released :: proc(button: sdl.MouseButtonFlag) -> bool
```
True only on the frame the button came back up.

```odin
capture_mouse :: proc()
```
Claims the pointer for whatever is drawn on top, for the rest of this frame.

```odin
release_mouse :: proc()
```
Hands the pointer back, for a widget that claimed it and has now drawn the thing it was protecting.

```odin
is_mouse_captured :: proc() -> bool
```
Whether something above has already claimed the pointer this frame.

### `gamepad.odin`

```odin
is_gamepad_connected :: proc(pad: int) -> bool
```
Whether a controller is in this slot.

```odin
get_gamepad_count :: proc() -> int
```
How many controllers are connected.

```odin
get_gamepad_name :: proc(pad: int) -> string
```
What the controller calls itself -- "Xbox Series X Controller" and such.

```odin
is_gamepad_button_pressed :: proc(pad: int, button: sdl.GamepadButton) -> bool
```
True only on the frame the button went down, and false for a pad nobody is holding -- so a game may ask about slot 3 whether or not anyone is in it.

```odin
is_gamepad_button_held :: proc(pad: int, button: sdl.GamepadButton) -> bool
```
True every frame the button is down.

```odin
is_gamepad_button_released :: proc(
	pad: int,
	button: sdl.GamepadButton,
) -> bool
```
True only on the frame the button came back up.

```odin
get_gamepad_axis :: proc(pad: int, axis: sdl.GamepadAxis) -> f32
```
One axis, normalised, with no deadzone applied.

```odin
get_gamepad_stick :: proc(pad: int, stick: Gamepad_Stick) -> [2]f32
```
A thumbstick as a direction, with the deadzone taken out.

```odin
get_gamepad_trigger :: proc(pad: int, trigger: Gamepad_Trigger) -> f32
```
A trigger's travel, 0 at rest and 1 fully depressed.

```odin
set_gamepad_deadzone :: proc(deadzone: f32)
```
How far a stick has to move before it counts, as a fraction of its full travel.

```odin
set_gamepad_trigger_threshold :: proc(threshold: f32)
```
How far a trigger must be pulled before it counts as pressed.

```odin
set_gamepad_rumble :: proc(pad: int, low: f32, high: f32, duration_ms: u32)
```
Shakes the controller.

### `touch.odin`

```odin
is_touch_active :: proc() -> bool
```
Whether input is currently coming from touch.

```odin
get_touch_count :: proc() -> int
```
How many fingers are down.

```odin
get_touch :: proc(slot: int) -> Touch
```
A finger by slot, 0 to MAX_TOUCHES-1.

```odin
get_primary_touch :: proc() -> (touch: Touch, ok: bool)
```
The first finger down, which is what a single-touch game wants without caring which slot it landed in.

```odin
is_touch_pressed :: proc(slot: int) -> bool
```
Whether a slot's finger went down this frame.

```odin
is_touch_down :: proc(slot: int) -> bool
```
Whether a slot's finger is on the glass.

```odin
is_touch_released :: proc(slot: int) -> bool
```
Whether a slot's finger came up this frame.

```odin
get_pinch :: proc() -> (distance: f32, change: f32, ok: bool)
```
The distance between the first two fingers, and how much it changed this frame.

## 2D drawing

### `render.odin`

```odin
begin_drawing :: proc()
```
Starts a frame: acquires a command buffer and the swapchain image.

```odin
end_drawing :: proc()
```
Ends the frame and hands it to the GPU.

```odin
clear_background :: proc(color: [4]f32 = {0, 0, 0, 1})
```
Fills the frame with one colour.

```odin
rect_center :: proc(rectangle: Rectangle) -> [2]f32
```
The middle of a rectangle, which is the point the vertex shader builds the quad around.

```odin
rect_top_left :: proc(rectangle: Rectangle) -> [2]f32
```
The top-left corner.

```odin
is_point_in_rect :: proc(point: [2]f32, rectangle: Rectangle) -> bool
```
Whether a point is inside a rectangle.

```odin
draw_rect :: proc(rectangle: Rectangle)
```
A filled rectangle, rotated about its own pivot.

### `sprite.odin`

```odin
create_mesh :: proc(bytes: []byte) -> (Mesh, Error)
```
Decoding is what loading an image costs -- the upload to the gpu underneath is nothing next to it -- so this goes through stb rather than core:image, which is roughly five times slower on the same file.

```odin
create_mesh_from_pixels :: proc(
	pixels: []byte,
	width,
	height: i32) -> (Mesh,
	Error,
)
```
The same, from pixels that have already been decoded.

```odin
create_sprite :: proc(bytes: []byte, scale: f32 = 1) -> (Sprite, Error)
```
A sprite from an encoded image -- PNG, JPG, whatever stb_image reads.

```odin
create_sprite_from_pixels :: proc(
	pixels: []byte,
	width,
	height: i32,
	scale: f32 = 1) -> (Sprite,
	Error,
)
```
A sprite around pixels the game already holds.

```odin
destroy_mesh :: proc(mesh: ^Mesh)
```
Only the texture is owned.

```odin
destroy_sprite :: proc(sprite: ^Sprite)
```
Gives the sprite's texture and vertex buffer back to the GPU.

```odin
sprite_center :: proc(sprite: Sprite) -> [2]f32
```
The middle of the sprite in world coordinates.

```odin
create_parallax :: proc(allocator := context.allocator) -> Parallax_Sprites
```
Layers that move with the camera at different rates, which is what reads as depth in a 2D scene.

```odin
parallax_add :: proc(set: ^Parallax_Sprites, sprite: Sprite, speed: f32 = 1)
```
Adds a layer, drawn in front of everything already in the set.

```odin
draw_parallax :: proc(set: Parallax_Sprites)
```
Draws every layer, first to last, so the set is ordered back to front.

```odin
destroy_parallax :: proc(parallax_sprites: ^Parallax_Sprites)
```
Destroys every layer of a parallax set, and the set's own storage.

```odin
draw_sprite :: proc(sprite: Sprite)
```
Draws a sprite at its position, turned about its pivot and multiplied by its tint.

```odin
sprite_bounds :: proc(body: ^Body) -> [4]f32
```
The body's collision rectangle as {left, top, right, bottom}, with its per-side padding applied.

```odin
draw_outline :: proc(
	center: [2]f32,
	size: [2]f32,
	color: [4]f32,
	thickness: f32,
	rotation: f32,
)
```
A hollow rectangle, `thickness` pixels thick on every side.

```odin
draw_outline_proportional :: proc(
	center: [2]f32,
	size: [2]f32,
	color: [4]f32,
	fraction: f32,
	rotation: f32,
)
```
A hollow rectangle whose border keeps its proportions as the shape changes.

```odin
draw_bounding_box_outline :: proc(body: ^Body, color: [4]f32, thickness: f32)
```
`thickness` is in pixels, the same on every side.

```odin
draw_rect_outline :: proc(body: ^Body, color: [4]f32, thickness: f32)
```
`thickness` is in pixels, the same on every side.

```odin
sprite_world_collision :: proc(sprite: Sprite) -> [2]f32
```
The sprite's position clamped so it cannot leave the visible area.

```odin
is_bounding_box_collision :: proc(a: [4]f32, b: [4]f32) -> bool
```
Whether two {left, top, right, bottom} rectangles overlap.

```odin
is_bounding_box_contact :: proc(a: [4]f32, b: [4]f32) -> bool
```
The same test as `is_bounding_box_collision`, except that touching counts.

```odin
sprite_forward_by_rotation :: proc(sprite: Sprite) -> [2]f32
```
Returns the forward direction vector of a sprite based on its current rotation.

```odin
look_at_sprite :: proc(
	sprite: Sprite,
	target: [2]f32,
	forward: Sprite_Forward = .TOP,
) -> f32
```
Returns the angle (radians) needed to face a sprite's visual center toward target.

```odin
sprite_set_frame :: proc(
	sprite: ^Sprite,
	col,
	row: int,
	tile_w,
	tile_h: f32,
	spacing: f32 = 0,
	margin: f32 = 0,
)
```
Selects a single tile from a sprite sheet by its column and row (0-indexed).

### `sprite_cache.odin`

```odin
create_sprite_cache :: proc(
	$Key: typeid,
	limit: int = 0,
	allocator := context.allocator) -> Sprite_Cache(Key,
)
```
A cache that loads each image once and hands the same sprite to everyone who asks for it, keyed by whatever a game already identifies its art by.

```odin
sprite_cache_get :: proc(
	cache: ^Sprite_Cache($Key),
	key: Key,
	path: string,
	scale: f32 = 1,
) -> ^Sprite
```
The sprite for `key`, loading it from `path` if this is the first ask.

```odin
sprite_cache_put :: proc(
	cache: ^Sprite_Cache($Key),
	key: Key,
	sprite: Sprite,
) -> ^Sprite
```
Puts a sprite the game made itself into the cache, under a key.

```odin
sprite_cache_find :: proc(cache: ^Sprite_Cache($Key), key: Key) -> ^Sprite
```
The sprite under a key, or nil, without loading anything.

```odin
is_sprite_cache_holding :: proc(cache: ^Sprite_Cache($Key), key: Key) -> bool
```
Whether a key is resident, without loading it.

```odin
get_sprite_cache_len :: proc(cache: ^Sprite_Cache($Key)) -> int
```
How many sprites are resident.

```odin
sprite_cache_evict :: proc(cache: ^Sprite_Cache($Key), key: Key)
```
Drops one entry.

```odin
destroy_sprite_cache :: proc(cache: ^Sprite_Cache($Key))
```
Frees every sprite and the cache's own storage.

### `shapes.odin`

```odin
draw_line :: proc(from: [2]f32, to: [2]f32, color: [4]f32, thickness: f32 = 1)
```
A straight line `thickness` pixels wide.

```odin
draw_lines :: proc(points: [][2]f32, color: [4]f32, thickness: f32 = 1)
```
A run of connected line segments.

```odin
draw_circle :: proc(center: [2]f32, radius: f32, color: [4]f32)
```
A filled circle.

```odin
draw_circle_outline :: proc(
	center: [2]f32,
	radius: f32,
	color: [4]f32,
	thickness: f32 = 1,
)
```
A circle drawn as a ring `thickness` pixels wide, centred on the radius.

```odin
draw_ellipse :: proc(
	center: [2]f32,
	radii: [2]f32,
	color: [4]f32,
	rotation: f32 = 0,
)
```
A filled ellipse.

```odin
draw_ellipse_outline :: proc(
	center: [2]f32,
	radii: [2]f32,
	color: [4]f32,
	thickness: f32 = 1,
	rotation: f32 = 0,
)
```
An ellipse drawn as a ring `thickness` pixels wide, centred on the edge.

```odin
draw_triangle :: proc(a, b, c: [2]f32, color: [4]f32)
```
A filled triangle through three points, in any winding order.

```odin
draw_triangle_outline :: proc(
	a,
	b,
	c: [2]f32,
	color: [4]f32,
	thickness: f32 = 1,
)
```
The same three points joined by a line `thickness` pixels wide.

### `image.odin`

```odin
load_image :: proc(
	bytes: []byte,
	allocator := context.allocator) -> (image: Image,
	err: Error,
)
```
Decodes an image held in memory.

```odin
load_image_from_file :: proc(
	path: string,
	allocator := context.allocator) -> (image: Image,
	err: Error,
)
```
The same, read from a path.

```odin
image_size :: proc(
	bytes: []byte) -> (width,
	height,
	channels: i32,
	err: Error,
)
```
How big an image is without decoding it.

```odin
image_pixel :: proc(image: Image, x, y: int) -> [4]u8
```
One pixel, or {0,0,0,0} when the coordinates are off the image.

```odin
destroy_image :: proc(image: ^Image)
```
Frees the pixels, through the allocator they came from.

### `pixel_buffer.odin`

```odin
create_pixel_buffer :: proc(width, height: i32) -> (Pixel_Buffer, Error)
```
An empty buffer `width` by `height` pixels.

```odin
pixel_buffer_update :: proc(buffer: ^Pixel_Buffer, pixels: []$T) -> Error
```
Hands this frame's pixels to the GPU.

```odin
draw_pixel_buffer :: proc(
	buffer: ^Pixel_Buffer,
	dest: Rectangle,
	tint: [4]f32 = WHITE,
)
```
Draws the buffer into `dest`, stretched to fill it.

```odin
pixel_buffer_fit :: proc(
	buffer: ^Pixel_Buffer,
	area: Rectangle = {},
	integer := false,
) -> Rectangle
```
The biggest box of the buffer's own shape that fits inside `area`, centred in it.

```odin
pixel_buffer_pick :: proc(
	buffer: ^Pixel_Buffer,
	dest: Rectangle,
	point: [2]f32) -> (x,
	y: int,
	ok: bool,
)
```
Which pixel of the buffer a point falls on.

```odin
pixel_buffer_pick_mouse :: proc(
	buffer: ^Pixel_Buffer,
	dest: Rectangle) -> (x,
	y: int,
	ok: bool,
)
```
pixel_buffer_pick with the pointer already filled in, which is what almost every caller wants -- the same shape as is_mouse_over_rect against is_point_in_rect.

```odin
destroy_pixel_buffer :: proc(buffer: ^Pixel_Buffer)
```
Gives back the texture and the staging buffer.

### `clip.odin`

```odin
begin_clip :: proc(rectangle: Rectangle)
```
Confines every draw until the matching end_clip.

```odin
end_clip :: proc()
```
Restores the clip that was in force before the matching begin_clip, or the whole window when that was the outermost one.

## Text and fonts

### `font.odin`

```odin
load_font :: proc(bytes: []byte, font_size: f32) -> (Font, Error)
```
Bakes a TTF into an atlas at one pixel size.

```odin
destroy_font :: proc(font: ^Font)
```
Gives the font's atlas texture and vertex buffer back to the GPU.

```odin
get_font :: proc(size: f32) -> ^Font
```
The default font baked at `size` pixels.

```odin
get_font_cache_len :: proc() -> int
```
How many extra sizes are resident, not counting the default one.

### `text.odin`

```odin
draw_text_i64 :: proc(
	font: ^Font,
	integer: i64,
	x: f32,
	y: f32,
	color: [4]f32,
)
```
An integer, without the caller building a string for it.

```odin
draw_text_2_i64 :: proc(
	font: ^Font,
	integers:[2]i64,
	x:f32,
	y:f32,
	color:[4]f32,
	separator:string = " ",
)
```
`strconv.write_float`'s leading sign, dropped when it is a plus and kept when it is a minus.

```odin
draw_text_2_float :: proc(
	font: ^Font,
	float: [2]$T,
	x: f32,
	y: f32,
	color: [4]f32,
	separator: string = " ",
)
```
Two floats separated by `separator` -- a position or a size, without the caller building a string for it.

```odin
draw_text_float :: proc(
	font: ^Font,
	float: $T,
	x: f32,
	y: f32,
	color: [4]f32) where intrinsics.type_is_float(T,
)
```
A float at two decimal places, without the caller building a string.

```odin
draw_text_string :: proc(
	font: ^Font,
	text: string,
	x: f32,
	y: f32,
	color: [4]f32,
)
```
A string at a position, in world coordinates -- so it moves with the camera and scales with the letterbox.

```odin
draw_text :: proc
```
Draws a string, an integer or a float, so a game does not build a string for a number it wants on screen.

```odin
measure_text :: proc(font: ^Font, text: string) -> [2]f32
```
How much room `text` takes up when drawn with draw_text.

```odin
draw_text_ui_string :: proc(
	font: ^Font,
	text: string,
	x: f32,
	y: f32,
	color: [4]f32,
)
```
Screen-space text — coordinates and glyph size are in actual window pixels, draw_scale is NOT applied.

```odin
draw_text_ui_int :: proc(
	font: ^Font,
	integer: i64,
	x: f32,
	y: f32,
	color: [4]f32,
)
```
An integer in screen coordinates.

```odin
draw_text_ui_f32 :: proc(
	font: ^Font,
	float: f32,
	x: f32,
	y: f32,
	color: [4]f32,
)
```
A float in screen coordinates, two decimal places.

```odin
draw_text_ui :: proc
```
`draw_text`, but in screen coordinates: fixed to the window and untouched by the camera.

```odin
wrap_text :: proc(
	font: ^Font,
	text: string,
	max_width: f32,
	allocator := context.allocator,
) -> []string
```
Splits `text` into lines that each fit within `max_width`.

```odin
line_height :: proc(
	font: ^Font,
	spacing: f32 = FONT_DEFAULTS.line_spacing,
) -> f32
```
The height of one line, baseline to baseline.

```odin
draw_text_wrapped :: proc(
	font: ^Font,
	text: string,
	top_left: [2]f32,
	max_width: f32,
	color: [4]f32 = WHITE,
	spacing: f32 = FONT_DEFAULTS.line_spacing,
) -> [2]f32
```
Draws `text` into a column `max_width` wide, from a top-left corner.

```odin
draw_text_lines :: proc(
	font: ^Font,
	lines: []string,
	top_left: [2]f32,
	color: [4]f32 = WHITE,
	spacing: f32 = FONT_DEFAULTS.line_spacing,
) -> [2]f32
```
Draws lines that have already been split, from a top-left corner.

```odin
measure_text_wrapped :: proc(
	font: ^Font,
	text: string,
	max_width: f32,
	spacing: f32 = FONT_DEFAULTS.line_spacing,
) -> [2]f32
```
How much room `text` takes when wrapped to `max_width`, without drawing it.

```odin
text_block_height :: proc(
	font: ^Font,
	count: int,
	spacing: f32 = FONT_DEFAULTS.line_spacing,
) -> f32
```
The height of `count` lines.

## 2D cameras

### `camera.odin`

```odin
begin_drawing_2d :: proc()
```
Activates the camera transform for all subsequent draw calls.

```odin
end_drawing_2d :: proc()
```
Deactivates the camera transform.

```odin
camera_follow :: proc(target: [2]f32, delta_time: f32)
```
Eases the camera toward `target`, once per frame.

```odin
get_mouse_world_pos :: proc() -> [2]f32
```
Returns the mouse position in world space, accounting for camera position and zoom.

## UI

### `ui.odin`

```odin
button :: proc(
	rectangle: Rectangle,
	text: string,
	style := BUTTON_STYLE,
	font: ^Font = nil,
) -> bool
```
A button that draws itself and answers in one call.

```odin
button_enabled_if :: proc(
	enabled: bool,
	style := BUTTON_STYLE,
) -> Button_Style
```
A style with `disabled` set the way the caller says, which is the shape this is nearly always wanted in: if matchbox.button(rect, "Play", matchbox.button_enabled_if(hand > 0)) { ...

```odin
is_mouse_over_rect :: proc(rectangle: Rectangle) -> bool
```
Whether the pointer is inside a rectangle and inside the clip in force.

```odin
button_confirm :: proc(
	state: ^Confirm_Button,
	rectangle: Rectangle,
	text: string,
	confirm_text: string,
	style := BUTTON_STYLE,
	armed_color := UI_DEFAULTS.confirm.armed,
	armed_hover := UI_DEFAULTS.confirm.armed_hover,
) -> bool
```
A button that asks first.

```odin
is_confirm_button_armed :: proc(state: ^Confirm_Button) -> bool
```
Whether it is currently asking.

```odin
hover_dwell :: proc(
	state: ^Hover,
	rectangle: Rectangle,
	seconds: f32 = UI_DEFAULTS.hover_dwell,
) -> bool
```
True once the pointer has rested inside `rectangle` for `seconds`.

```odin
hover_progress :: proc(
	state: ^Hover,
	seconds: f32 = UI_DEFAULTS.hover_dwell,
) -> f32
```
How far through the dwell the pointer is, 0 to 1.

```odin
draw_button :: proc(button:Button)
```
Draws a button without asking whether it was clicked -- the drawing half of `button`, for a game that decides on its own terms what a click means.

```odin
is_mouse_over_button :: proc(button:Button) -> bool
```
Whether the pointer is inside the button's rectangle.

```odin
draw_text_plate :: proc(
	font: ^Font,
	text: string,
	top_left: [2]f32,
	color: [4]f32 = UI_DEFAULTS.text_plate.fg,
	plate: [4]f32 = UI_DEFAULTS.text_plate.bg,
	padding: [2]f32 = UI_DEFAULTS.text_plate.padding,
) -> [2]f32
```
Text on a dark plate cut to fit it.

```odin
draw_rect_border :: proc(rectangle:Rectangle, color:[4]f32, thickness:f32)
```
A border of one even thickness all the way round, in pixels.

```odin
destroy_text_field :: proc(field:^Text_Field)
```
Frees what the field owns.

```odin
get_text_field_string :: proc(field:^Text_Field) -> string
```
What has been typed.

```odin
text_field_set :: proc(field:^Text_Field, text:string)
```
Replaces the contents outright, putting the caret at the end*/

```odin
is_mouse_over_text_field :: proc(field:^Text_Field) -> bool
```
Whether the pointer is inside the field's box.

```odin
update_text_field :: proc(field:^Text_Field)
```
Takes this frame's input, when the field has focus.

```odin
text_field_insert :: proc(field:^Text_Field, text:string)
```
Puts text in at the caret, as far as max_bytes allows.

```odin
text_field_label_height :: proc(field:^Text_Field, font:^Font = nil) -> f32
```
How much room the label takes above the box, gap included.

```odin
text_field_height :: proc(
	field:^Text_Field,
	box_height:f32,
	font:^Font = nil,
) -> f32
```
The whole height a field occupies, label included, for a box `box_height` tall.

```odin
text_field_place :: proc(
	field:^Text_Field,
	top_left:[2]f32,
	size:[2]f32,
	font:^Font = nil,
)
```
Puts the field where the whole thing -- label and box together -- starts at `top_left`, with a box `size` big.

```odin
draw_text_field :: proc(field:^Text_Field, font:^Font = nil)
```
Draws the label, the box, what is in it, and the caret.

```odin
text_field_shown :: proc(
	field:^Text_Field,
	allocator := context.allocator,
) -> string
```
What the field puts on screen: its text, or one star per character when masked*/

```odin
text_field_shown_caret :: proc(field:^Text_Field) -> int
```
Where the caret sits within text_field_shown, which masking makes a different string*/

```odin
begin_scroll :: proc(
	view: ^Scroll_View,
	area: Rectangle,
	content_height: f32,
) -> [2]f32
```
Starts a scrolling panel and returns the top-left to lay content out from.

```odin
end_scroll :: proc(view: ^Scroll_View)
```
Ends the panel and draws the scrollbar.

```odin
get_scroll_max :: proc(view: ^Scroll_View) -> f32
```
The furthest the content can be scrolled.

```odin
is_scroll_needed :: proc(view: ^Scroll_View) -> bool
```
Whether there is anything to scroll.

```odin
scroll_to :: proc(view: ^Scroll_View, top: f32, height: f32)
```
Brings a band of content into view, given in the coordinates it was laid out in -- offsets from the top of the content, not from the top of the panel.

```odin
scrollbar_track_rect :: proc(view: ^Scroll_View) -> Rectangle
```
The track the thumb runs in, down the panel's right edge.

```odin
scrollbar_thumb_rect :: proc(view: ^Scroll_View) -> Rectangle
```
The thumb, as long as the share of the content on screen and as far down as the share already scrolled past.

```odin
draw_scrollbar :: proc(view: ^Scroll_View)
```
Draws the track and thumb, and nothing at all when everything fits.

```odin
dropdown :: proc(
	state: ^Dropdown,
	rectangle: Rectangle,
	options: []string,
	style: Dropdown_Style = DROPDOWN_STYLE,
	font: ^Font = nil) -> (changed: bool,
)
```
The closed box, and every scrap of input for the frame.

```odin
open_context_menu :: proc(state: ^Dropdown, point: [2]f32, row_size: [2]f32)
```
Opens the list at a point, with no box: a context menu.

```odin
context_menu :: proc(
	state: ^Dropdown,
	options: []string,
	style: Dropdown_Style = DROPDOWN_STYLE) -> (chosen: int,
	picked: bool,
)
```
The input half of a context menu.

```odin
dropdown_overlay :: proc(
	state: ^Dropdown,
	options: []string,
	style: Dropdown_Style = DROPDOWN_STYLE,
	font: ^Font = nil,
)
```
The open list, drawn over whatever came after it.

```odin
is_dropdown_open :: proc(state: ^Dropdown) -> bool
```
Whether a dropdown is showing its list, for a caller deciding what else to draw.

```odin
dropdown_close :: proc(state: ^Dropdown)
```
Shuts the list without changing the choice.

```odin
dropdown_list_rect :: proc(state: ^Dropdown, count: int) -> Rectangle
```
The whole open list.

```odin
dropdown_row_rect :: proc(
	state: ^Dropdown,
	index: int,
	count: int,
) -> Rectangle
```
One row of the open list.

```odin
dropdown_row_at :: proc(state: ^Dropdown, count: int, point: [2]f32) -> int
```
Which row a point is on, or -1 for none of them.

```odin
draw_tooltip :: proc(
	text: string,
	font: ^Font = nil,
	max_width: f32 = TOOLTIP_MAX,
	color: [4]f32 = UI_DEFAULTS.text_plate.fg,
	plate: [4]f32 = UI_DEFAULTS.text_plate.bg,
	padding: [2]f32 = UI_DEFAULTS.text_plate.padding,
) -> Rectangle
```
Text on a plate beside the pointer, moved to the other side when it would run off the screen.

```odin
set_status :: proc(
	status: ^Status_Line,
	text: string,
	level: Status_Level = .INFO,
	seconds: f32 = 0,
)
```
Puts a message on the line, replacing whatever was there.

```odin
clear_status :: proc(status: ^Status_Line)
```
Takes the message off the line.

```odin
get_status_text :: proc(status: ^Status_Line) -> string
```
What is on the line.

```odin
status_alpha :: proc(status: ^Status_Line) -> f32
```
How visible the line should be, 0 to 1.

```odin
draw_status :: proc(
	status: ^Status_Line,
	top_left: [2]f32,
	font: ^Font = nil,
) -> [2]f32
```
Draws the line at a top-left, in its level's colour, and returns the room it took.

```odin
open_modal :: proc(modal: ^Modal)
```
Puts the modal up.

```odin
close_modal :: proc(modal: ^Modal)
```
Closes the modal.

```odin
is_modal_open :: proc(modal: ^Modal) -> bool
```
Whether the modal is up.

```odin
modal_begin :: proc(modal: ^Modal) -> bool
```
Takes the pointer for the frame while the modal is up.

```odin
modal_overlay :: proc(
	modal: ^Modal,
	size: [2]f32,
	dim: [4]f32 = MODAL_DIM) -> (content: Rectangle,
	open: bool,
)
```
Draws the dim and hands back a centred box to put content in.

```odin
is_modal_dismissed :: proc(content: Rectangle) -> bool
```
Whether the click landed on the dim rather than on `content`, which is the usual way a modal is dismissed.

```odin
number_field :: proc(
	state: ^Number_Field,
	rectangle: Rectangle,
	value: ^f32,
	style: Number_Field_Style = NUMBER_FIELD_STYLE,
	font: ^Font = nil) -> (changed: bool,
)
```
A number changed by dragging sideways across it, or by clicking and typing.

```odin
is_number_field_active :: proc(state: ^Number_Field) -> bool
```
Whether the field is being dragged or typed into.

```odin
destroy_number_field :: proc(state: ^Number_Field)
```
Frees the text the field types into.

```odin
toggle :: proc(
	rectangle: Rectangle,
	value: ^bool,
	label: string = "",
	style: Toggle_Style = TOGGLE_STYLE,
	font: ^Font = nil) -> (changed: bool,
)
```
A box that is ticked or not, with its label beside it.

```odin
slider :: proc(
	state: ^Slider,
	rectangle: Rectangle,
	value: ^f32,
	low: f32,
	high: f32,
	step: f32 = 0,
	style: Slider_Style = SLIDER_STYLE) -> (changed: bool,
)
```
A number picked by dragging, between `low` and `high`.

```odin
slider_int :: proc(
	state: ^Slider,
	rectangle: Rectangle,
	value: ^int,
	low: int,
	high: int,
	style: Slider_Style = SLIDER_STYLE) -> (changed: bool,
)
```
The same, over whole numbers.

```odin
slider_handle_rect :: proc(
	rectangle: Rectangle,
	value,
	low,
	high: f32,
	style: Slider_Style = SLIDER_STYLE,
) -> Rectangle
```
Where the handle sits for a given value.

```odin
draw_progress :: proc(
	rectangle: Rectangle,
	progress: f32,
	style: Progress_Style = PROGRESS_STYLE,
)
```
A bar from 0 to 1, filling left to right.

```odin
draw_progress_labelled :: proc(
	rectangle: Rectangle,
	progress: f32,
	text: string,
	style: Progress_Style = PROGRESS_STYLE,
	color: [4]f32 = WHITE,
	font: ^Font = nil,
)
```
The same bar with a label centred on it.

```odin
progress_percent :: proc(
	progress: f32,
	allocator := context.allocator,
) -> string
```
Percentage text for a bar, as "42%".

### `layout.odin`

```odin
create_layout :: proc(
	top_left: [2]f32,
	width: f32,
	spacing: f32 = 0,
) -> Layout
```
A column starting at `top_left`, `width` across, with `spacing` between items.

```odin
layout_next :: proc(layout: ^Layout, height: f32, width: f32 = 0) -> Rectangle
```
The next box down the column, `height` tall, and the cursor moves past it.

```odin
layout_space :: proc(layout: ^Layout, amount: f32)
```
Leaves a gap.

```odin
layout_text :: proc(
	layout: ^Layout,
	font: ^Font,
	text: string,
	color: [4]f32 = {1, 1, 1, 1},
)
```
Draws one line of text at the cursor and moves past it.

```odin
layout_height :: proc(layout: ^Layout, from_y: f32) -> f32
```
Where the cursor has reached.

```odin
create_grid :: proc(
	area: Rectangle,
	target: [2]f32,
	count: int,
	spacing: f32 = 0,
) -> Grid
```
Works out how to fit `count` items of about `target` size into `area`.

```odin
grid_cell :: proc(grid: Grid, index: int) -> Rectangle
```
The box for item `index`, filling left to right and then down.

```odin
grid_height :: proc(grid: Grid) -> f32
```
How tall the whole grid is, which is what a scroll extent is measured against and what a panel sized to its contents needs.

## 3D cameras

### `camera3d.odin`

```odin
create_camera3d :: proc(position, target: [3]f32, fov: f32 = 70) -> Camera3D
```
A camera at `position` looking at `target`, with everything else left to the defaults.

```odin
camera3d_view :: proc(camera: Camera3D) -> matrix[4, 4]f32
```
The matrix that moves the world in front of the camera.

```odin
camera3d_projection :: proc(camera: Camera3D) -> matrix[4, 4]f32
```
The matrix that turns view space into clip space, for wherever 3D is being drawn now: the bound render target, or the window when none is bound.

```odin
camera3d_view_projection :: proc(camera: Camera3D) -> matrix[4, 4]f32
```
Both at once, in the order a vertex shader wants them.

```odin
camera3d_forward :: proc(camera: Camera3D) -> [3]f32
```
The direction the camera looks.

```odin
camera3d_right :: proc(camera: Camera3D) -> [3]f32
```
Sideways from the camera, to the right.

```odin
direction_from_angles :: proc(yaw, pitch: f32) -> [3]f32
```
Which way you are facing, from the two angles.

```odin
camera3d_angles :: proc(camera: Camera3D) -> (yaw, pitch: f32)
```
The angles that would produce the direction a camera is already looking in.

```odin
camera3d_look :: proc(
	yaw,
	pitch: ^f32,
	sensitivity: f32 = CAMERA3D_DEFAULTS.sensitivity,
	pitch_min: f32 = -CAMERA3D_DEFAULTS.pitch_limit,
	pitch_max: f32 = CAMERA3D_DEFAULTS.pitch_limit,
)
```
Turns this frame's mouse motion into a change in yaw and pitch.

```odin
camera3d_aim :: proc(camera: ^Camera3D, yaw, pitch: f32)
```
Points the camera along `yaw` and `pitch` from wherever it currently is.

```odin
walk_direction :: proc(yaw: f32) -> [3]f32
```
Which way WASD is asking to go, flattened onto the ground and normalised.

```odin
camera3d_first_person :: proc(
	camera: ^Camera3D,
	yaw,
	pitch: ^f32,
	speed: f32,
	delta_time: f32,
	sensitivity: f32 = CAMERA3D_DEFAULTS.sensitivity,
)
```
Mouse look and WASD, moving the camera directly.

```odin
camera3d_zoom :: proc(
	distance: ^f32,
	min_distance: f32 = CAMERA3D_DEFAULTS.distance_min,
	max_distance: f32 = CAMERA3D_DEFAULTS.distance_max,
	speed: f32 = CAMERA3D_DEFAULTS.zoom_speed,
)
```
Turns this frame's wheel into a change in distance.

```odin
camera3d_shoulder_amount :: proc(
	shoulder: Camera3D_Shoulder,
	offset: f32 = CAMERA3D_DEFAULTS.shoulder_offset,
) -> f32
```
The signed sideways step a shoulder setting asks for.

```odin
camera3d_side_offset :: proc(yaw: f32, amount: f32) -> [3]f32
```
The world-space slide, for a signed amount.

```odin
camera3d_orbit_focus :: proc(
	focus: [3]f32,
	yaw: f32,
	shoulder: Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = CAMERA3D_DEFAULTS.shoulder_offset,
) -> [3]f32
```
The point an orbit camera actually looks at: the focus, stepped sideways by the shoulder setting.

```odin
camera3d_orbit_position :: proc(
	focus: [3]f32,
	yaw,
	pitch,
	distance: f32,
	shoulder: Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = CAMERA3D_DEFAULTS.shoulder_offset,
) -> [3]f32
```
Where an orbit camera wants to be: `distance` back from the focus, along the direction the angles describe, off whichever shoulder was asked for.

```odin
camera3d_follow :: proc(
	camera: ^Camera3D,
	focus: [3]f32,
	yaw,
	pitch,
	distance: f32,
	shoulder: Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = CAMERA3D_DEFAULTS.shoulder_offset,
)
```
Seats the camera behind `focus` and points it at it.

```odin
camera3d_orbit_angles :: proc(camera: Camera3D) -> (yaw, pitch, distance: f32)
```
The angles and distance an orbit camera is already at.

```odin
camera3d_third_person :: proc(
	camera: ^Camera3D,
	focus: [3]f32,
	yaw,
	pitch,
	distance: ^f32,
	shoulder: Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = CAMERA3D_DEFAULTS.shoulder_offset,
	sensitivity: f32 = CAMERA3D_DEFAULTS.sensitivity,
	pitch_min: f32 = CAMERA3D_DEFAULTS.orbit_pitch_min,
	pitch_max: f32 = CAMERA3D_DEFAULTS.orbit_pitch_max,
)
```
Mouse look, wheel zoom, and the camera placed behind `focus`.

```odin
yaw_from_direction :: proc(direction: [3]f32) -> f32
```
Which way a flat direction points, as a yaw.

```odin
turn_toward :: proc(angle: ^f32, target: f32, speed: f32, delta_time: f32)
```
Turns `angle` toward `target` the short way round, at most `speed` radians per second, and lands exactly on it.

```odin
facing_rotation :: proc(yaw: f32) -> quaternion128
```
The rotation that turns a model to face `yaw`.

```odin
model_facing_rotation :: proc(facing: Model_Facing) -> quaternion128
```
The rotation that brings a model's own forward onto +x, which is the direction the rest of this file assumes.

```odin
facing_rotation_of :: proc(yaw: f32, facing: Model_Facing) -> quaternion128
```
`facing_rotation` for a model that is not authored facing +x.

```odin
aim_rotation :: proc(
	yaw,
	pitch: f32,
	facing := Model_Facing.POS_X,
) -> quaternion128
```
The rotation that points a model along both angles -- yaw and pitch.

```odin
create_first_person_camera :: proc(
	position: [3]f32 = {0, 0, 0},
	facing: f32 = 0,
	eye_offset: [3]f32 = CAMERA3D_DEFAULTS.eye_offset,
	pitch: f32 = 0,
	fov: f32 = 70,
	near: f32 = 0.1,
	far: f32 = 1000,
	sensitivity: f32 = CAMERA3D_DEFAULTS.sensitivity,
	pitch_min: f32 = -CAMERA3D_DEFAULTS.pitch_limit,
	pitch_max: f32 = CAMERA3D_DEFAULTS.pitch_limit,
) -> First_Person_Camera
```
A first-person camera, set up and already looking where it was told to.

```odin
first_person_input :: proc(rig: ^First_Person_Camera)
```
Reads the mouse and the keys into the rig.

```odin
first_person_aim :: proc(rig: ^First_Person_Camera, position: [3]f32)
```
Puts the eye above `position` and points it along the angles.

```odin
first_person_walk :: proc(
	rig: ^First_Person_Camera,
	position: ^[3]f32,
	speed: f32,
	delta_time: f32,
)
```
Input, the move, and the aim -- the whole frame, for a body nothing else is driving.

```odin
create_third_person_camera :: proc(
	position: [3]f32 = {0, 0, 0},
	facing: f32 = 0,
	focus_offset: [3]f32 = CAMERA3D_DEFAULTS.focus_offset,
	distance: f32 = CAMERA3D_DEFAULTS.distance,
	pitch: f32 = CAMERA3D_DEFAULTS.orbit_pitch,
	shoulder: Camera3D_Shoulder = .CENTER,
	shoulder_offset: f32 = CAMERA3D_DEFAULTS.shoulder_offset,
	steering: Camera3D_Steering = .CAMERA,
	turn_speed: f32 = CAMERA3D_DEFAULTS.turn_speed,
	fov: f32 = 70,
	near: f32 = 0.1,
	far: f32 = 1000,
	sensitivity: f32 = CAMERA3D_DEFAULTS.sensitivity,
	pitch_min: f32 = CAMERA3D_DEFAULTS.orbit_pitch_min,
	pitch_max: f32 = CAMERA3D_DEFAULTS.orbit_pitch_max,
	zoom_speed: f32 = CAMERA3D_DEFAULTS.zoom_speed,
	distance_min: f32 = CAMERA3D_DEFAULTS.distance_min,
	distance_max: f32 = CAMERA3D_DEFAULTS.distance_max,
) -> Third_Person_Camera
```
A third-person camera, set up and already pointed at the character.

```odin
third_person_input :: proc(rig: ^Third_Person_Camera)
```
Reads the mouse, the wheel and the keys into the rig.

```odin
third_person_follow :: proc(
	rig: ^Third_Person_Camera,
	position: [3]f32,
	delta_time: f32,
)
```
Turns the character and seats the camera behind them, at wherever they actually ended up.

```odin
third_person_walk :: proc(
	rig: ^Third_Person_Camera,
	position: ^[3]f32,
	speed: f32,
	delta_time: f32,
)
```
Input, the move, and the follow -- the whole frame, for a character nothing else is driving.

### `camera3d_fixed.odin`

```odin
create_fixed_camera :: proc(
	focus_offset: [3]f32 = CAMERA3D_DEFAULTS.focus_offset,
	near: f32 = 0.1,
	far: f32 = 1000,
	allocator := context.allocator,
) -> Fixed_Camera
```
An empty fixed camera, waiting for shots.

```odin
fixed_camera_add_shot :: proc(rig: ^Fixed_Camera, shot: Camera_Shot) -> int
```
Adds a shot, and answers its index in `shots`.

```odin
fixed_camera_follow :: proc(rig: ^Fixed_Camera, position: [3]f32)
```
Puts the camera at the shot covering `position`, and aims it.

```odin
destroy_fixed_camera :: proc(rig: ^Fixed_Camera)
```
Releases the shots.

### `math3d.odin`

```odin
transform_identity :: proc() -> Transform
```
A Transform that does nothing: at the origin, unturned, full size.

```odin
create_transform :: proc(
	position: [3]f32,
	rotation := linalg.QUATERNIONF32_IDENTITY,
	scale: f32 = 1,
) -> Transform
```
A Transform at `position`, turned by `rotation`, at one scale on every axis.

```odin
transform_rotation :: proc(axis: [3]f32, angle_radians: f32) -> quaternion128
```
Turn about an axis, in radians.

```odin
transform_matrix :: proc(t: Transform) -> matrix[4, 4]f32
```
Scale, then rotate, then translate -- the order that turns a model about its own centre rather than swinging it around the origin.

```odin
transform_from_matrix :: proc(m: matrix[4, 4]f32) -> Transform
```
A matrix back into the translation, rotation and scale it was built from -- the inverse of `transform_matrix`.

```odin
perspective :: proc(fov_degrees, aspect, near, far: f32) -> matrix[4, 4]f32
```
A perspective projection with a [0, 1] depth range.

```odin
ortho :: proc(left, right, bottom, top, near, far: f32) -> matrix[4, 4]f32
```
An orthographic projection, also [0, 1] in depth.

```odin
look_at_matrix :: proc(eye, target, up: [3]f32) -> matrix[4, 4]f32
```
A view matrix for an eye looking at a point.

## 3D movement

### `movement3d.odin`

```odin
create_character_controls :: proc(
	facing: f32 = 0,
	scheme: Control_Scheme = .TANK,
	tank_turn_speed: f32 = MOVEMENT_DEFAULTS.tank_turn_speed,
	backward_speed: f32 = MOVEMENT_DEFAULTS.backward_speed,
	turn_speed: f32 = CAMERA3D_DEFAULTS.turn_speed,
	hold_basis: bool = true,
	hold_tolerance: f32 = MOVEMENT_DEFAULTS.hold_tolerance,
) -> Character_Controls
```
Character controls, facing `facing`, with everything else defaulted.

```odin
get_movement_input :: proc(pad: int = 0) -> [2]f32
```
The movement the player is asking for this frame, from the keys and a pad.

```odin
character_steer :: proc(
	controls: ^Character_Controls,
	input: [2]f32,
	camera: Camera3D,
	delta_time: f32,
)
```
Turns the character and works out `move` from `input`, under `camera`.

```odin
character_walk :: proc(
	controls: ^Character_Controls,
	position: ^[3]f32,
	speed: f32,
	camera: Camera3D,
	delta_time: f32,
	pad: int = 0,
)
```
`character_steer` with this frame's `get_movement_input`, and the move added to `position` -- the whole frame, for a character nothing else is driving.

## 3D drawing

### `render3d.odin`

```odin
begin_drawing_3d :: proc(camera: Camera3D)
```
Opens the 3D pass and fixes the camera for everything drawn until `end_drawing_3d`.

```odin
end_drawing_3d :: proc()
```
Closes the 3D pass and resolves it.

```odin
is_drawing_3d :: proc() -> bool
```
Whether a 3D pass is open.

```odin
current_camera3d :: proc() -> Camera3D
```
The camera the open 3D pass was started with.

```odin
draw_model :: proc(
	model: Model,
	transform: Transform,
	tint: [4]f32 = WHITE,
	animator: ^Animator = nil,
	casts_shadow: bool = false,
)
```
Draws every part of a model, placed by `transform` and multiplied by `tint`.

```odin
draw_model_at :: proc(
	model: Model,
	position: [3]f32,
	scale: f32 = 1,
	tint: [4]f32 = WHITE,
	animator: ^Animator = nil,
	casts_shadow: bool = false,
)
```
A model at a position, at one scale on every axis and unturned.

```odin
draw_model_pivoted :: proc(
	model: Model,
	pivot: [3]f32,
	transform: Transform,
	tint: [4]f32 = WHITE,
	animator: ^Animator = nil,
)
```
Draws a model placed and turned about `pivot` rather than about its origin.

### `shapes3d.odin`

```odin
draw_cube :: proc(
	position: [3]f32,
	size: [3]f32,
	color: [4]f32 = WHITE,
	rotation: quaternion128 = 1,
	casts_shadow: bool = false,
)
```
A box at `position`, `size` units across each axis.

```odin
draw_plane :: proc(position: [3]f32, size: [2]f32, color: [4]f32 = WHITE)
```
A flat square on the ground plane at `position`, facing up.

```odin
draw_sphere :: proc(position: [3]f32, radius: f32 = 1, color: [4]f32 = WHITE)
```
A sphere of `radius` at `position`.

```odin
draw_cube_wires :: proc(
	position: [3]f32,
	size: [3]f32,
	color: [4]f32 = BLACK,
	rotation: quaternion128 = 1,
)
```
The twelve edges of a box, same arguments as `draw_cube`.

```odin
draw_bounds_wires :: proc(lower, upper: [3]f32, color: [4]f32 = WHITE)
```
The same box, given by its corners rather than its middle.

```odin
draw_grid :: proc(
	slices: int = 10,
	spacing: f32 = 1,
	color: [4]f32 = {1, 1, 1, 0.35},
)
```
A grid of lines on the ground plane, centred on the origin, `slices` squares across and `spacing` units to a square.

### `light.odin`

```odin
create_point_light :: proc(
	position: [3]f32,
	color: [4]f32 = WHITE,
	casts_shadow := false,
) -> Light
```
A point light at `position`.

```odin
create_directional_light :: proc(
	direction: [3]f32,
	color: [4]f32 = WHITE,
	casts_shadow := false,
) -> Light
```
A light shining along `direction`, from nowhere in particular.

```odin
create_spot_light :: proc(
	position: [3]f32,
	direction: [3]f32,
	color: [4]f32 = WHITE,
	inner_angle: f32 = 20,
	outer_angle: f32 = 30,
	casts_shadow: bool = false,
) -> Light
```
A cone of light at `position`, pointing along `direction`.

```odin
create_area_rect_light :: proc(
	position: [3]f32,
	normal: [3]f32,
	right: [3]f32,
	width: f32,
	height: f32,
	color: [4]f32 = WHITE,
) -> Light
```
A flat rectangle of light at `position`, facing `normal`, `width` wide along `right` and `height` wide along the axis square to both.

```odin
create_area_disk_light :: proc(
	position: [3]f32,
	normal: [3]f32,
	radius: f32,
	color: [4]f32 = WHITE,
) -> Light
```
A flat disk of light at `position`, facing `normal`, `radius` wide.

```odin
set_lights :: proc(lights: []Light)
```
Sets every light in the scene at once, replacing whatever was there.

```odin
pick_shadow_casters :: proc(lights: []Light) -> (casters: Shadow_Casters)
```
Which lights in a list `set_lights` would give a shadow to: `slots` for directional and spot lights, `cube` for point lights, each an index into `lights`, or -1 for a slot nobody took.

```odin
is_shadow_caster :: proc(casters: Shadow_Casters, index: int) -> bool
```
Whether the light at `index` in the list `casters` was picked from gets a shadow slot.

### `skybox.odin`

```odin
load_skybox_panorama :: proc(path: string) -> (skybox: Skybox, err: Error)
```
An equirectangular panorama, from a 2:1 image.

```odin
load_skybox_cubemap :: proc(path: string) -> (skybox: Skybox, err: Error)
```
A cube map, from the six faces of a horizontal cross.

```odin
destroy_skybox :: proc(skybox: ^Skybox)
```
Releases the sky's texture.

```odin
draw_skybox :: proc(skybox: Skybox)
```
Draws the sky behind everything else.

## Models

### `model.odin`

```odin
model_center :: proc(model: Model) -> [3]f32
```
The middle of the model's own bounds, and how big it is.

```odin
model_size :: proc(model: Model) -> [3]f32
```
How big the model is on each axis, in its own space before any Transform.

```odin
upload_mesh :: proc(
	vertices: []Vertex3D,
	indices: []u32,
	topology := Mesh_Topology.TRIANGLES) -> (Model_Part,
	Error,
)
```
Puts one lump of geometry on the GPU.

```odin
create_model_from_mesh :: proc(
	vertices: []Vertex3D,
	indices: []u32,
	topology := Mesh_Topology.TRIANGLES) -> (Model,
	Error,
)
```
A model of one part, from one lump of geometry.

```odin
destroy_model :: proc(model: ^Model)
```
Gives a model's buffers, textures, skeleton and clips back.

```odin
create_cube_model :: proc(size: f32 = 1) -> (Model, Error)
```
A cube of `size` units, centred on its own origin.

```odin
create_plane_model :: proc(size: f32 = 1) -> (Model, Error)
```
A flat square of `size` units on the ground plane, facing up.

```odin
create_sphere_model :: proc(
	radius: f32 = 1,
	rings: int = 16,
	sectors: int = 24) -> (Model,
	Error,
)
```
A sphere of `radius`, built the usual way out of rings of latitude and sectors of longitude.

```odin
create_cube_wires_model :: proc(size: f32 = 1) -> (Model, Error)
```
The twelve edges of a cube, as lines.

```odin
create_grid_model :: proc(
	slices: int = 10,
	spacing: f32 = 1) -> (Model,
	Error,
)
```
A grid of lines on the ground plane, centred on the origin.

### `model_load.odin`

```odin
load_model :: proc(
	path: string,
	shading: Maybe(Shading_Model) = nil) -> (model: Model,
	err: Error,
)
```
Loads a model from a `.gltf` or `.glb` file.

## Animation

### `animation.odin`

```odin
create_animated_sprite :: proc(
	bytes: []byte,
	frame_w: f32,
	frame_h: f32,
	cols: i32,
	rows: i32,
	frame_count: i32,
	seconds_per_frame: f32,
	scale: f32 = 1,
	looping := true) -> (Animated_Sprite,
	Error,
)
```
A sprite that plays frames off a sheet, in one call.

```odin
load_animation :: proc(
	bytes: []byte,
	frame_w: f32,
	frame_h: f32,
	cols: i32,
	rows: i32,
	frame_count: i32,
	seconds_per_frame: f32) -> (Animation_Clip,
	Error,
)
```
The clip on its own, without a sprite wrapped round it.

```odin
load_animation_frames :: proc(
	frames: [][]byte,
	seconds_per_frame: f32,
	columns: i32 = 0) -> (clip: Animation_Clip,
	err: Error,
)
```
A clip from frames that arrived as separate image files.

```odin
load_animation_directory :: proc(
	files: []runtime.Load_Directory_File,
	seconds_per_frame: f32,
	columns: i32 = 0,
	suffixes: []string = {".png", ".jpg", ".jpeg", ".bmp", ".tga"}) -> (clip: Animation_Clip,
	err: Error,
)
```
A clip from a whole folder of frames, in the order a person would read them.

```odin
animation_range :: proc(
	clip: Animation_Clip,
	first: i32,
	last: i32,
	seconds_per_frame: f32 = 0,
) -> Animation_Clip
```
A stretch of a sheet as a clip of its own -- walk, idle and jump off one set of frames -- given as the first and last frame, inclusive, and clamped to the frames the sheet actually has.

```odin
create_animated_sprite_from_clip :: proc(
	clip: Animation_Clip,
	scale: f32 = 1,
	looping := true,
) -> Animated_Sprite
```
A sprite ready to play `clip`, with everything that is not obviously yours already set.

```odin
destroy_animation_clip :: proc(clip: ^Animation_Clip)
```
Gives the clip's sheet texture back to the GPU.

```odin
destroy_animated_sprite :: proc(sprite: ^Animated_Sprite)
```
Frees the sheet an animated sprite draws from.

```odin
switch_animation :: proc(
	sprite: ^Animated_Sprite,
	clip: Animation_Clip,
	looping := true,
)
```
Puts a different clip on a sprite and restarts it from frame zero.

```odin
replay_animation :: proc(sprite: ^Animated_Sprite)
```
Starts the current clip again from its first frame.

```odin
queue_animation :: proc(
	sprite: ^Animated_Sprite,
	clip: Animation_Clip,
	looping: bool,
)
```
Lines a clip up to play when the current one finishes.

```odin
clear_animation_queue :: proc(sprite: ^Animated_Sprite)
```
Forgets everything lined up behind the current clip, which carries on playing.

```odin
update_animation :: proc(sprite: ^Animated_Sprite, delta_time: f32)
```
Advances the sprite's frame and works out its uv window.

```odin
get_animation_frame :: proc(sprite: Animated_Sprite) -> i32
```
Which frame of the clip is showing, counting from 0.

```odin
get_animation_progress :: proc(sprite: Animated_Sprite) -> f32
```
How far through the clip playback is, 0 to 1.

```odin
is_animation_in_window :: proc(
	sprite: Animated_Sprite,
	first,
	last: i32,
) -> bool
```
Whether playback is somewhere in `first ..= last`, counting from 0.

```odin
is_animation_frame_passed :: proc(sprite: Animated_Sprite, frame: i32) -> bool
```
Whether the last `update_animation` crossed *into* `frame`, counting from 0.

```odin
draw_animated_sprite :: proc(sprite: Animated_Sprite)
```
Draws the current frame.

### `animation3d.odin`

```odin
is_model_skinned :: proc(model: Model) -> bool
```
Whether a model has a skeleton at all.

```odin
create_animator :: proc(
	model: Model,
	// Blending on,
	over a fifth of a second. Passed as one value rather than as // loose arguments so that the setting and its duration travel together,
	and // so there is no package-level constant for either. blend := Animation_Blend{enabled = true, duration = 0.2},
) -> Animator
```
An animator for `model`, with nothing playing.

```odin
destroy_animator :: proc(animator: ^Animator)
```
Frees an animator's working arrays and resets it.

```odin
animation_index :: proc(
	model: Model,
	name: string) -> (index: int,
	found: bool,
)
```
The index of a clip by name, for a game that would rather write "Walk" than remember which number it came out as.

```odin
animation_names :: proc(
	model: Model,
	allocator := context.temp_allocator,
) -> []string
```
What the clips in a model are called, in the order `play_animation_index` numbers them.

```odin
node_index :: proc(model: Model, name: string) -> (node: u32, found: bool)
```
The index of a skeleton node by name -- the bone to hang a weapon off.

```odin
node_names :: proc(
	model: Model,
	allocator := context.temp_allocator,
) -> []string
```
What a model's skeleton nodes are called, indexed by node.

```odin
node_matrix :: proc(
	model: Model,
	animator: Animator,
	node: u32,
) -> matrix[4, 4]f32
```
Where a skeleton node has been posed, in the model's own space.

```odin
node_world_matrix :: proc(
	model: Model,
	animator: Animator,
	node: u32,
	transform: Transform,
	pivot: [3]f32 = {0, 0, 0},
) -> matrix[4, 4]f32
```
Where a skeleton node has been posed, in the world -- the matrix to hang a weapon off.

```odin
print_skeleton :: proc(model: Model)
```
Prints a model's skeleton -- every node, its parent, its name, and which joint of which skin it is, to stdout.

```odin
print_animations :: proc(model: Model)
```
Prints what a model's skeleton and clips are, to stdout.

```odin
play_animation :: proc(
	animator: ^Animator,
	model: Model,
	name: string,
	looping: bool = true,
) -> bool
```
Starts a clip by name, from the beginning.

```odin
play_animation_index :: proc(
	animator: ^Animator,
	model: Model,
	index: int,
	looping: bool = true,
)
```
The same by index, for a game that resolved the name once and kept it.

```odin
stop_animation :: proc(animator: ^Animator)
```
Stops where it is.

```odin
replay_animation_3d :: proc(animator: ^Animator)
```
Starts the current clip again from its first frame.

```odin
animation_mask_below :: proc(
	model: Model,
	root: u32,
	allocator := context.allocator,
) -> []bool
```
Every node at or below `root` in the hierarchy -- the mask for "everything from the spine up" or "everything from the hip down".

```odin
animation_mask_named :: proc(
	model: Model,
	names: []string,
	allocator := context.allocator,
) -> []bool
```
A mask covering exactly the named nodes, for a set that is not one clean subtree -- a face and a hand rig for a full-body wince, say.

```odin
play_animation_layer :: proc(
	animator: ^Animator,
	model: Model,
	layer: int,
	name: string,
	mask: []bool,
	looping: bool = true,
) -> bool
```
Starts `name` playing on `layer`, masked to `mask`.

```odin
stop_animation_layer :: proc(animator: ^Animator, layer: int)
```
Stops a layer where it is and drops it from the composition -- the masked joints fall back to whatever the base (or a layer beneath it) says, on the very next update.

```odin
set_animation_layer_weight :: proc(
	animator: ^Animator,
	layer: int,
	weight: f32,
)
```
Sets how strongly `layer` overrides its masked joints, 0 (off) to 1 (full override).

```odin
update_animator :: proc(animator: ^Animator, model: Model, delta_time: f32)
```
Advances the clip and works out this frame's matrices.

## VRM

### `vrm.odin`

```odin
vrm_version :: proc(extensions: gltf.Extensions) -> Vrm_Version
```
Reads which VRM spec, if any, a parsed file's `extensions` object carries.

```odin
vrm_facing_correction :: proc(version: Vrm_Version) -> quaternion128
```
The turn a VRM file's rest pose needs before it agrees with everything else in this package.

```odin
vrm_bone :: proc(model: Model, bone: Vrm_Bone) -> (node: u32, found: bool)
```
The node playing `bone` in this model's humanoid map, if the file said so.

```odin
load_animation_source :: proc(
	path: string,
	rest_pose_path := "") -> (source: Animation_Source,
	err: Error,
)
```
Loads a clip set and the skeleton it was authored against, from a `.glb` or `.gltf` (or, since both are GLB containers underneath, a `.vrm`) -- without paying for a mesh upload this is never going to draw.

```odin
destroy_animation_source :: proc(src: ^Animation_Source)
```
Gives an `Animation_Source`'s skeleton and clips back.

```odin
retarget_animations :: proc(
	dst: ^Model,
	src: Animation_Source,
	names: []Vrm_Bone_Name = UNREAL_BONE_NAMES) -> (added: int,
)
```
Copies every clip in `src` onto `dst`, rewriting each track to drive the bone playing the same humanoid role, and returns how many clips landed at least one track.

## Render targets

### `render_target.odin`

```odin
create_render_target :: proc(
	width: i32 = 0,
	height: i32 = 0) -> (Render_Target,
	Error,
)
```
Makes a render target `width` by `height`, or the size of the window when either is left at zero.

```odin
destroy_render_target :: proc(target: ^Render_Target)
```
Releases the target's colour and depth textures.

```odin
begin_drawing_target :: proc(target: ^Render_Target)
```
Sends everything drawn from here until `end_drawing_target` into `target` rather than the window.

```odin
end_drawing_target :: proc()
```
Back to the window.

```odin
draw_post :: proc(
	target: Render_Target,
	effect: Post_Effect = .NONE,
	grid: [2]f32 = {320, 240},
)
```
Draws a render target over the whole window, through `effect`.

```odin
draw_render_target :: proc(target: Render_Target, dest: Rectangle)
```
Draws a render target into `dest`, stretched to fill it: the part of the window a split-screen player, an in-game monitor or an editor's viewport takes up.

## Sound

### `sound.odin`

```odin
load_sound :: proc(bytes: []byte) -> Sound
```
A WAV from bytes, so `#load` works and the sound ships inside the executable.

```odin
destroy_sound :: proc(sound: ^Sound)
```
Frees the decoded samples.

```odin
play_sound :: proc(sound: ^Sound)
```
Plays the sound once, immediately.

## Tiled maps

### `collisions.odin`

```odin
sprite_to_index_by_sprite :: proc(player:Sprite) -> (index:int)
```
Converts a sprites x and y into a 1D array index This is row-major so all the rows are stored consecutively

```odin
sprite_to_index_by_value :: proc(x:f32, y:f32, width:f32) -> (index:int)
```
A grid coordinate as an index into a row-major array of `width` columns.

```odin
is_mouse_over_sprite :: proc(sprite:Sprite) -> bool
```
Whether the pointer is over a sprite.

## Other

### `ambient.odin`

```odin
create_environment_probe :: proc(
	source: Skybox,
	settings: Environment_Probe_Settings = ENVIRONMENT_PROBE_DEFAULTS) -> (probe: Environment_Probe,
	err: Error,
)
```
Bakes `source`'s own cube map into a new `Environment_Probe` -- does **not** install it as the scene's own ambient; call `set_environment_probe` with the result to do that.

```odin
set_environment_probe :: proc(probe: Environment_Probe)
```
Installs `probe` as the scene's own environment probe, releasing whatever was bound before -- `set_lighting`'s own "replace the whole struct" shape, applied to the one piece of ambient/environment state that is a GPU resource rather than a plain value and therefore cannot live on `Lighting_Settings` itself (see that struct's own doc comment).

```odin
destroy_environment_probe :: proc(probe: ^Environment_Probe)
```
Releases a probe's own two textures.

### `lighting.odin`

```odin
set_lighting :: proc(settings: Lighting_Settings = LIGHTING_DEFAULTS)
```
Applies `settings` to the scene: whether lighting runs, whether shadows do and with what parameters, ambient, fog.

```odin
is_lighting_active :: proc() -> bool
```
Whether the lighting model is currently running.

### `material.odin`

```odin
create_material_phong :: proc(
	base_color: [4]f32 = WHITE,
	specular_power: f32 = 16,
	textures: Material_Textures = {},
) -> Material
```
A lit, Blinn-Phong-shaded material.

```odin
create_material_unlit :: proc(
	base_color: [4]f32 = WHITE,
	textures: Material_Textures = {},
) -> Material
```
A material no light reaches -- `shade_surface` (lighting_core.hlsli) returns `base_color` for one of these regardless of what the scene's lights or `Lighting_Settings.enabled` say, the same as it does for every surface when lighting is off scene-wide.

```odin
create_material_pbr_metallic :: proc(
	base_color: [4]f32 = WHITE,
	metallic: f32 = 0,
	roughness: f32 = 0.5,
	emissive: [3]f32 = {0, 0, 0},
	textures: Material_Textures = {},
) -> Material
```
Cook-Torrance GGX under the metallic-roughness parameterization -- `brdf/pbr_metallic.hlsli` is the shading model this reads into.

```odin
create_material_pbr_specgloss :: proc(
	base_color: [4]f32 = WHITE,
	specular: [3]f32 = {0.04, 0.04, 0.04},
	glossiness: f32 = 0.5,
	emissive: [3]f32 = {0, 0, 0},
	textures: Material_Textures = {},
) -> Material
```
The same Cook-Torrance BRDF as `create_material_pbr_metallic`, under glTF's specular-glossiness parameterization instead -- `brdf/pbr_specgloss.hlsli` reads `specular` as the surface's reflectance at normal incidence directly (no metallic lerp) and `glossiness` as the inverse of roughness.

```odin
create_material_toon :: proc(
	base_color: [4]f32 = WHITE,
	bands: f32 = 4,
	rim: f32 = 0,
	emissive: [3]f32 = {0, 0, 0},
	textures: Material_Textures = {},
) -> Material
```
Cel shading -- `brdf/toon.hlsli` reads `bands` as how many discrete steps the diffuse response quantizes into (4, this proc's own default, is a common cel-shading choice: a dark band, two mid bands and a lit one) and `rim` as the strength of a silhouette-edge highlight, 0 by default because not every toon-shaded material wants one.

```odin
create_material_subsurface :: proc(
	base_color: [4]f32 = WHITE,
	subsurface: [3]f32 = {1, 1, 1},
	thickness: f32 = 0.5,
	emissive: [3]f32 = {0, 0, 0},
	textures: Material_Textures = {},
) -> Material
```
A wrapped-diffuse translucency approximation -- see `brdf/subsurface.hlsli`'s own doc comment for exactly what this does and does not model (it is not a real BSSRDF).

### `ray.odin`

```odin
ray_point :: proc(ray: Ray, distance: f32) -> [3]f32
```
The point `distance` along a ray.

```odin
ray_from_screen :: proc(
	camera: Camera3D,
	point: [2]f32,
	viewport: Rectangle = {},
) -> Ray
```
The ray from the camera through a point on the screen.

```odin
get_mouse_ray :: proc(camera: Camera3D, viewport: Rectangle = {}) -> Ray
```
The ray under the pointer.

```odin
world_to_screen :: proc(
	camera: Camera3D,
	point: [3]f32,
	viewport: Rectangle = {}) -> (screen: [2]f32,
	in_front: bool,
)
```
Where a point in the world lands on the screen, and whether it is in front of the camera at all.

```odin
ray_plane :: proc(
	ray: Ray,
	point,
	normal: [3]f32) -> (distance: f32,
	hit: bool,
)
```
Where a ray meets the plane through `point` facing `normal`, as a distance along the ray.

```odin
ray_sphere :: proc(
	ray: Ray,
	center: [3]f32,
	radius: f32) -> (distance: f32,
	hit: bool,
)
```
Where a ray first meets a sphere, as a distance along the ray.

```odin
ray_box :: proc(ray: Ray, lower, upper: [3]f32) -> (distance: f32, hit: bool)
```
Where a ray first enters a box whose sides run along the axes, as a distance along the ray; 0 when it starts inside.

```odin
ray_oriented_box :: proc(
	ray: Ray,
	lower,
	upper: [3]f32,
	transform: matrix[4, 4]f32) -> (distance: f32,
	hit: bool,
)
```
`ray_box` for a box placed by `transform`: `lower` and `upper` are in the box's own space, and the distance comes back in the world's.

```odin
ray_model :: proc(
	ray: Ray,
	model: Model,
	transform: Transform) -> (distance: f32,
	hit: bool,
)
```
Where a ray meets a model drawn at `transform`, against the model's bounding box: what clicking on a model wants.

### `reflection.odin`

```odin
add_reflection_probe :: proc(
	position: [3]f32,
	radius: f32,
	falloff: f32 = REFLECTION_PROBE_FALLOFF,
) -> int
```
Places a probe and hands back its slot, or -1 when the scene already has `MAX_REFLECTION_PROBES` of them.

```odin
clear_reflection_probes :: proc()
```
Forgets every placed probe.

```odin
get_reflection_probe_count :: proc() -> int
```
How many probes the scene currently has placed.

```odin
begin_probe_capture :: proc(index: int, face: int) -> bool
```
Opens a pass rendering face `face` of probe `index`'s own capture cube, from the probe's position, at a ninety-degree field of view.

```odin
end_probe_capture :: proc()
```
Closes the capture pass opened by `begin_probe_capture`.

```odin
bake_reflection_probe :: proc(index: int) -> bool
```
Convolves whatever the six capture passes left in the capture cube into probe `index`'s own slice of the two shared arrays: one irradiance face per face, and one prefiltered face per roughness level per face.

### `shadow.odin`

```odin
pcss_uv_radius :: proc(light_size, extent: f32) -> f32
```
`Shadow_Settings.light_size` (world units) converted into the ortho shadow map's own UV units -- `shaders/shadow/pcss.hlsli` has no other way to learn `extent` (see that file's own top comment), so `push_lighting` (lighting.odin) does this division once, here, rather than pushing `extent` itself just for this one technique to divide by every fragment.

### `shadow_cascaded.odin`

```odin
compute_cascade_splits :: proc(
	near,
	far: f32,
	count: int,
	lambda: f32,
) -> [MAX_CASCADES]f32
```
Splits `[near, far]` into up to `MAX_CASCADES` sub-ranges, each entry being that cascade's own far edge (its near edge is the previous entry's far edge, or `near` itself for cascade 0) -- the "practical split scheme" most real-time renderers use: a `lambda` blend of a uniform split (every cascade the same depth range) and a logarithmic one (every cascade closer to the same *projected* footprint, since perspective already compresses distant depth into fewer screen pixels on its own).

```odin
begin_cascade_shadow_pass :: proc(slot: int, cascade: int) -> bool
```
Opens the shadow pass for `slot`'s `cascade`-th map (0 up to `Shadow_Settings.cascade_count`, not inclusive).

### `shadow_cube.odin`

```odin
shadow_cube_face_index :: proc(direction: [3]f32) -> int
```
Which of the six faces built by `shadow_cube_face_direction` a direction away from the light falls into -- the ordinary major-axis cubemap face test (whichever axis has the largest magnitude component picks the pair, that component's sign picks which of the pair), mirrored exactly in `shaders/shadow/cube.hlsli`'s own `shadow_cube_face_index`.

```odin
begin_point_shadow_pass :: proc(face: int) -> bool
```
Opens the shadow pass for the single point-light caster's `face`-th map (0..5, `shadow_cube_face_direction`'s own order).

### `shadow_standard.odin`

```odin
is_shadows_active :: proc() -> bool
```
Whether the shadow system is currently running -- set_lighting's own Lighting_Settings.shadows.enabled, as last resolved.

```odin
begin_shadow_pass :: proc(slot: int = 0) -> bool
```
Opens the shadow pass for `slot` (0 or 1 -- see `MAX_SHADOW_CASTERS`): works out that slot's own caster's view-projection, then a depth-only render pass against that slot's shadow map, ready for whatever `draw_model` calls come next to render into it as occluders rather than as the visible scene.

```odin
end_shadow_pass :: proc()
```
Closes the shadow pass.

### `utility.odin`

```odin
start_cooldown :: proc(cooldown: ^Cooldown_Timer, duration: f32)
```
Starts the cooldown.

```odin
update_cooldown :: proc(cooldown: ^Cooldown_Timer, delta_time: f32)
```
Advances the cooldown by delta_time.

```odin
is_cooldown_done :: proc(cooldown: Cooldown_Timer) -> bool
```
Returns true once the cooldown has fully elapsed.

```odin
reset_cooldown :: proc(cooldown: ^Cooldown_Timer)
```
Resets remaining back to the original duration, restarting the countdown.

```odin
stop_cooldown :: proc(cooldown: ^Cooldown_Timer)
```
Immediately expires the cooldown (sets remaining to 0).

```odin
create_lerp_move :: proc(position: [2]f32, duration: f32) -> Lerp_Move
```
Creates a Lerp_Move anchored at position.

```odin
lerp_move_to :: proc(lerp: ^Lerp_Move, current_position: [2]f32, dest: [2]f32)
```
Sets a new destination.

```odin
update_lerp_move :: proc(lerp: ^Lerp_Move, delta_time: f32) -> [2]f32
```
Advances the lerp by delta_time and returns the new position.

```odin
look_at_point :: proc(
	from: [2]f32,
	target: [2]f32,
	forward: Sprite_Forward = .TOP,
) -> f32
```
Returns the angle (radians) needed to face from a point toward target.

```odin
look_at :: proc
```
The angle that points something at a target, given either a plain position or a sprite.

