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
*/
create_pixel_buffer :: proc(width, height: i32) -> Pixel_Buffer {
	ensure(width > 0 && height > 0, "a pixel buffer needs a positive width and height")

	transfer := sdl.CreateGPUTransferBuffer(mbi.renderer.device, {
		usage = .UPLOAD,
		size  = u32(width) * u32(height) * 4,
	})
	ensure(transfer != nil, "could not create the pixel buffer's transfer buffer")

	return Pixel_Buffer{
		mesh = {
			texture = create_gpu_texture(width, height),
			sampler = mbi.renderer.sprite_sampler,
			width   = width,
			height  = height,
		},
		transfer = transfer,
	}
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
pixel_buffer_update :: proc(buffer: ^Pixel_Buffer, pixels: []$T) {
	size := int(buffer.width) * int(buffer.height) * 4

	ensure(len(pixels) * size_of(T) == size,
		"pixel buffer update is the wrong size -- it must be width * height * 4 bytes of RGBA")

	r := &mbi.renderer

	// No command buffer this frame, which is a minimized or zero-sized window.
	// Nothing is being drawn either, so skipping the upload loses nothing.
	if !r.frame_active || r.cmd == nil do return

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
	if dst == nil do return

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
}

/*
	Draws the buffer into `dest`, stretched to fill it.

	`dest.color` is ignored -- a Rectangle is taken for its geometry and its
	pivot, so pixel_buffer_fit's result and a hand-made box both go straight in.
	`tint` multiplies, the same as a sprite's, which is how a screen is faded out
	or flashed without touching the pixels.
*/
draw_pixel_buffer :: proc(buffer: ^Pixel_Buffer, dest: Rectangle, tint: [4]f32 = WHITE) {
	vert_data := VertData{
		position = screen_pos(rect_center(dest)),
		size     = screen_size(dest.size),
		screen   = screen_dims(),
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

// Gives back the texture and the staging buffer. Reachable through `destroy`.
destroy_pixel_buffer :: proc(buffer: ^Pixel_Buffer) {
	if buffer.transfer != nil && mbi.renderer.device != nil {
		sdl.ReleaseGPUTransferBuffer(mbi.renderer.device, buffer.transfer)
	}
	buffer.transfer = nil

	destroy_mesh(&buffer.mesh)
}
