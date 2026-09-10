package matchbox

/*
	Pixel_Buffer
	------------
	A texture whose pixels are rewritten every frame.

	This is what an emulator draws with, and matchbox had no way to do it at all.
	Everything here loaded a texture from a *file* -- create_sprite takes encoded
	bytes and runs them through stb -- and nothing could hand over a buffer it had
	filled in itself, let alone hand over a new one sixty times a second.

	The shape is the same in every emulator that has ever been written: keep one
	small texture the size of the machine's screen, rewrite its pixels once per
	emulated frame, and draw it scaled up with nearest-neighbour filtering so the
	pixels stay square. A Game Boy is 160x144, a Chip-8 is 64x32, an NES is
	256x240.

		screen := matchbox.create_pixel_buffer(160, 144)
		defer matchbox.destroy(&screen)

		for matchbox.is_running() {
			matchbox.poll_events()
			run_one_emulated_frame()

			matchbox.begin_drawing()
			matchbox.pixel_buffer_update(&screen, ppu.framebuffer[:])
			matchbox.clear_background(matchbox.BLACK)
			matchbox.draw_pixel_buffer(&screen, matchbox.pixel_buffer_fit(&screen))
			matchbox.end_drawing()
		}

	It is not only for emulators. Anything generating an image a pixel at a time
	-- a software rasteriser, a raytracer, a plasma, a mandelbrot -- wants exactly
	this and nothing more.

	**Why this is not just create_sprite in a loop.** Making a fresh texture each
	frame would allocate a texture and a transfer buffer, submit its own command
	buffer, and leak the previous texture -- and releasing the previous one is not
	safe while the GPU may still be reading from it. The upload here goes onto the
	frame's *existing* command buffer, and both the texture and the staging buffer
	are created once and kept.
*/

import "base:runtime"

import sdl "vendor:sdl3"

/*
	Held by the caller. One per screen being emulated.

	`mesh` is the same bundle a Sprite carries, so `width`, `height` and the
	texture are where they always are, and the nearest-neighbour sampler is the
	one every sprite already shares -- which is what a scaled-up pixel image
	wants, and would otherwise be the first thing to go wrong.
*/
Pixel_Buffer :: struct {
	using mesh: Mesh,

	// Staging, kept rather than made per frame. SDL cycles it when the GPU is
	// still reading last frame's copy, so writing into it never stalls and
	// never has to be double-buffered by hand.
	transfer: ^sdl.GPUTransferBuffer,
}

/*
	An empty buffer `width` by `height` pixels. Black and fully transparent until
	the first update.

	Give it the resolution of the thing being emulated, not the size it will be
	drawn at -- the scaling up happens at draw time, which is what keeps one
	pixel one pixel.

	The size is answerable rather than fatal because it is often not the
	program's own number -- `image.odin`'s own example opens a file and hands
	over what came back.
*/
create_pixel_buffer :: proc(width, height: i32) -> (Pixel_Buffer, Error) {
	if width <= 0 || height <= 0 do return {}, Argument_Error.Empty_Size

	transfer := sdl.CreateGPUTransferBuffer(mbi.renderer.device, {
		usage = .UPLOAD,
		size  = u32(width) * u32(height) * 4,
	})
	if transfer == nil do return {}, Gpu_Error.Transfer_Buffer_Creation_Failed

	// UNORM: a Pixel_Buffer is drawn through draw_pixel_buffer, the same 2D
	// path a sprite takes -- straight to the swapchain, nothing downstream to
	// re-encode a decoded value. See Texture_Encoding.
	texture, err := create_gpu_texture(width, height, .UNORM)
	if err != nil {
		sdl.ReleaseGPUTransferBuffer(mbi.renderer.device, transfer)
		return {}, err
	}

	return Pixel_Buffer{
		mesh = {
			texture = texture,
			sampler = mbi.renderer.sprite_sampler,
			width   = width,
			height  = height,
		},
		transfer = transfer,
	}, nil
}

/*
	Hands this frame's pixels to the GPU. RGBA, one byte a channel, row by row
	from the top.

	`pixels` may be a slice of anything four bytes wide -- `[]u8` at four entries
	a pixel, `[][4]u8`, `[]u32`, or an emulator's own `[]COLOR` -- and the total
	is checked against the buffer's size, so a mismatched stride is a panic here
	rather than a picture that looks nearly right. Nothing is kept: the bytes are
	copied out during this call and the caller's buffer is free immediately.

	**Call it inside begin_drawing/end_drawing**, since the copy is recorded onto
	the frame's command buffer. Before `clear_background` is the cheapest place: a
	copy cannot be recorded while a render pass is open, so calling it after
	drawing has started closes the pass and the next draw reopens it. That is
	correct, just not free.

	Being on the frame's own command buffer is also what makes the upload and the
	draw that reads it ordered against each other. Doing this through a separate
	submit is where the "sometimes draws last frame's image" class of bug comes
	from -- raylib's backend carries a comment about Windows drivers deferring
	uploads made outside the draw context, and this is the arrangement that
	problem does not have.
*/
pixel_buffer_update :: proc(buffer: ^Pixel_Buffer, pixels: []$T) -> Error {
	size := int(buffer.width) * int(buffer.height) * 4

	/*
		An abort rather than a returned error, unlike the map failure below.

		The two look alike and are not. A transfer buffer can fail to map at
		any time, for reasons outside the program -- that is a runtime
		condition and comes back as a `Gpu_Error`. This is the caller handing
		over an array of the wrong length, and the length is fixed by the
		buffer's dimensions and the caller's own type: right on the first
		frame means right on the ten-thousandth. Returning it would make a
		programming mistake ignorable, which is the opposite of useful, and
		`Error` is easy to drop on a procedure called every frame.
	*/
	ensure(len(pixels) * size_of(T) == size,
		"pixel_buffer_update was given an array that is not width * height * 4 bytes")

	r := &mbi.renderer

	// No command buffer this frame, which is a minimized or zero-sized window.
	// Nothing is being drawn either, so skipping the upload loses nothing.
	if !r.frame_active || r.cmd == nil do return nil

	// A copy pass cannot be opened while a render pass is recording. Whatever
	// has been drawn is already in the swapchain, and ensure_pass reopens with
	// load_op = .LOAD, so closing it here costs a pass and not a picture.
	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// `cycle` on both: the whole texture is being replaced and the staging buffer
	// entirely rewritten, so there is nothing in either worth waiting for. This
	// is what keeps a per-frame upload from stalling on the GPU still reading
	// last frame's copy.
	dst := sdl.MapGPUTransferBuffer(r.device, buffer.transfer, true)
	if dst == nil do return Gpu_Error.Transfer_Buffer_Map_Failed

	runtime.mem_copy(dst, raw_data(pixels), size)
	sdl.UnmapGPUTransferBuffer(r.device, buffer.transfer)

	pass := sdl.BeginGPUCopyPass(r.cmd)
	sdl.UploadToGPUTexture(
		pass,
		{
			transfer_buffer = buffer.transfer,
			offset          = 0,
			pixels_per_row  = u32(buffer.width),
			rows_per_layer  = u32(buffer.height),
		},
		{texture = buffer.texture, w = u32(buffer.width), h = u32(buffer.height), d = 1},
		true,
	)
	sdl.EndGPUCopyPass(pass)

	return nil
}

/*
	Draws the buffer into `dest`, stretched to fill it.

	`dest.color` is ignored -- a Rectangle is taken for its geometry and its
	pivot, so pixel_buffer_fit's result and a hand-made box both go straight in.
	`tint` multiplies, the same as a sprite's, which is how a screen is faded out
	or flashed without touching the pixels.
*/
draw_pixel_buffer :: proc(buffer: ^Pixel_Buffer, dest: Rectangle, tint: [4]f32 = WHITE) {
	vert_data := Vert_Data{
		position = screen_pos(rect_center(dest)),
		size     = screen_size(dest.size),
		screen   = get_screen_dims(),
		rotation = dest.rotation,
		uv_min   = {0, 0},
		uv_max   = {1, 1},
	}

	frag_data := Sprite_Frag_Data{color = tint}

	draw_quad(
		mbi.renderer.pipelines.sprite, &vert_data, &frag_data, size_of(frag_data),
		buffer.texture, buffer.sampler,
	)
}

/*
	The biggest box of the buffer's own shape that fits inside `area`, centred in
	it. `area` defaults to the whole window.

	This is the arithmetic every emulator writes for itself and gets subtly
	wrong. Stretching the image to fill the window instead -- which is what both
	of the ones this was written for do -- distorts it whenever the window is not
	an exact multiple of the machine's aspect ratio.

	`integer` snaps the scale down to a whole number, so one source pixel is an
	exact block of screen pixels. That is what a pixel-art display actually
	wants: at 2.6x, some rows of a Game Boy screen are three pixels tall and
	others two, and the unevenness is visible on a dithered gradient in a way it
	is not on a photograph. It costs a black margin, which is the trade -- and at
	a scale below 1 it is ignored, since snapping down would reach zero.
*/
pixel_buffer_fit :: proc(buffer: ^Pixel_Buffer, area: Rectangle = {}, integer := false) -> Rectangle {
	area := area
	if area.size.x <= 0 || area.size.y <= 0 {
		area = {size = {f32(mbi.width), f32(mbi.height)}, pivot = {0.5, 0.5}}
	}

	source := [2]f32{f32(buffer.width), f32(buffer.height)}
	if source.x <= 0 || source.y <= 0 do return area

	scale := min(area.size.x / source.x, area.size.y / source.y)

	// Below 1 there is no whole number to snap to but zero, so a window smaller
	// than the machine's screen keeps the fractional scale and stays visible.
	if integer && scale > 1 do scale = f32(int(scale))

	size     := source * scale
	top_left := rect_top_left(area) + (area.size - size) * 0.5

	return Rectangle{
		position = top_left,
		size     = size,
		pivot    = {0.5, 0.5}, // position is the top-left corner
	}
}

/*
	Which pixel of the buffer a point falls on. `ok` is false when it falls
	outside, and then x and y mean nothing.

	This is the other direction from drawing, and anything that paints needs it:
	the pointer arrives in screen coordinates and the thing being edited is an
	array index.

	`dest` is the rectangle the buffer was *drawn* into -- pass the same one, do
	not work it out again here. That is the entire reason it is a parameter: a
	pick that recomputed the destination could disagree with what is on screen
	the moment a caller draws somewhere other than pixel_buffer_fit's answer, and
	the symptom would be a brush that paints a pixel or two away from the cursor.

		dest := matchbox.pixel_buffer_fit(&canvas, integer = true)
		matchbox.draw_pixel_buffer(&canvas, dest)

		if x, y, ok := matchbox.pixel_buffer_pick_mouse(&canvas, dest); ok {
			if matchbox.is_mouse_held(.LEFT) do pixels[y * WIDTH + x] = colour
		}

	Works in the space `get_mouse_position` reports, which is after the letterbox
	and the display's pixel density have been taken off. It does **not** account
	for a camera: draw_pixel_buffer runs `dest` through screen_pos and so is moved
	by an active camera, while this is not. Panning a canvas with mbi.camera
	rather than by moving `dest` wants get_mouse_world_pos as the point.
*/
pixel_buffer_pick :: proc(buffer: ^Pixel_Buffer, dest: Rectangle, point: [2]f32) -> (x, y: int, ok: bool) {
	if buffer.width <= 0 || buffer.height <= 0 do return 0, 0, false
	if dest.size.x <= 0 || dest.size.y <= 0    do return 0, 0, false

	top_left := rect_top_left(dest)

	// Per axis. pixel_buffer_fit never hands back a destination of a different
	// shape to the buffer, but a caller is free to, and then the two scales are
	// different numbers.
	fx := (point.x - top_left.x) / (dest.size.x / f32(buffer.width))
	fy := (point.y - top_left.y) / (dest.size.y / f32(buffer.height))

	/*
		Bounds-checked as floats, before the conversion, and that ordering is the
		whole substance of this procedure.

		`int()` in Odin truncates toward zero rather than flooring, so a point four
		screen pixels to the left of a canvas drawn at 9x gives -0.44 and converts
		to 0 -- a perfectly valid index. Checking the range afterwards lets that
		through, and what you get is a brush that paints the leftmost column while
		the pointer is outside the picture. Every hand-rolled version of this has
		the bug, because the check looks right.

		Once fx is known to be non-negative, int() and floor() agree, so nothing
		further is needed.
	*/
	if fx < 0 || fy < 0 do return 0, 0, false
	if fx >= f32(buffer.width) || fy >= f32(buffer.height) do return 0, 0, false

	return int(fx), int(fy), true
}

// pixel_buffer_pick with the pointer already filled in, which is what almost
// every caller wants -- the same shape as is_mouse_over_rect against
// is_point_in_rect.
pixel_buffer_pick_mouse :: proc(buffer: ^Pixel_Buffer, dest: Rectangle) -> (x, y: int, ok: bool) {
	return pixel_buffer_pick(buffer, dest, get_mouse_position())
}

// Gives back the texture and the staging buffer. Reachable through `destroy`.
destroy_pixel_buffer :: proc(buffer: ^Pixel_Buffer) {
	if buffer.transfer != nil && mbi.renderer.device != nil {
		sdl.ReleaseGPUTransferBuffer(mbi.renderer.device, buffer.transfer)
	}
	buffer.transfer = nil

	destroy_mesh(&buffer.mesh)
}
