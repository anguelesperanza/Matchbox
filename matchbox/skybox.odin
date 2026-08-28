package matchbox

/*
	Skybox
	------
	The sky, drawn as whatever direction each pixel happens to look in.

	Two source formats, because the two are what sky packs ship as and neither
	converts to the other without loss:

	  - **panorama**, one 2:1 equirectangular image. Longitude across, latitude
	    down. What a 360 camera produces and what most sky generators export
	  - **cube map**, six square faces packed into one image as a cross. What a
	    game engine wants natively -- the hardware does the face selection, so
	    it samples in a compare and a divide where a panorama costs an atan2 and
	    an acos

	Both end up in the same `Skybox` and are drawn by the same call. A game
	swapping one for the other changes the loader it calls and nothing else.

	The sky is drawn first, before anything else in the 3D pass, and neither
	tests nor writes depth. That is what makes it a background rather than a
	very large object: everything drawn afterwards covers it, and it never
	covers anything.
*/

import "core:log"
import "core:math"

import sdl "vendor:sdl3"

Skybox_Kind :: enum {
	PANORAMA,
	CUBEMAP,
}

/*
	A loaded sky.

	`tint` multiplies the texture on the way out, which is the cheap way to
	darken a sky for dusk or push it toward a colour without a second image.
	White leaves it as the file has it.
*/
Skybox :: struct {
	kind:    Skybox_Kind,
	texture: ^sdl.GPUTexture,
	sampler: ^sdl.GPUSampler,
	tint:    [4]f32,
}

// -----------------------------------------------------------------------
// Loading
// -----------------------------------------------------------------------

/*
	An equirectangular panorama, from a 2:1 image.

	The ratio is checked rather than assumed. A panorama that is not 2:1 is
	almost always a cube cross handed to the wrong loader, and the symptom -- a
	sky squashed and turning at the wrong rate -- is a poor way to find that
	out. It loads anyway, because a slightly-off ratio is a legitimate crop and
	refusing would be worse than saying so.
*/
load_skybox_panorama :: proc(path: string) -> (skybox: Skybox, ok: bool) {
	image := load_image_from_file(path) or_return
	defer destroy_image(&image)

	ratio := f32(image.width) / f32(image.height)
	if abs(ratio - 2) > 0.01 {
		log.warnf("%s is %vx%v, a ratio of %.2f rather than the 2.00 an equirectangular panorama has",
			path, image.width, image.height, ratio)
	}

	skybox = Skybox{
		kind    = .PANORAMA,
		texture = upload_texture(raw_data(image.pixels), image.width, image.height),
		sampler = mbi.renderer.skybox_wrap_sampler,
		tint    = WHITE,
	}

	return skybox, true
}

/*
	A cube map, from the six faces of a horizontal cross.

	The layout, which is the one every cross-packed sky pack uses:

		        +Y
		 -X     +Z     +X     -Z
		        -Y

	Four cells across, three down, each face square, and the six cells off the
	cross left blank. The image is therefore 4:3 with a width divisible by four,
	and both are checked -- the alternative is slicing a vertical cross into six
	wrong rectangles and uploading them without complaint.

	Faces are taken by the cross's own labels and uploaded in the order the API
	numbers them: +X, -X, +Y, -Y, +Z, -Z. The handedness is dealt with in the
	shader rather than by swapping faces here, so that what this slices is what
	a person sees when they open the file.
*/
load_skybox_cubemap :: proc(path: string) -> (skybox: Skybox, ok: bool) {
	image := load_image_from_file(path) or_return
	defer destroy_image(&image)

	if image.width % 4 != 0 || image.height % 3 != 0 || image.width / 4 != image.height / 3 {
		log.errorf("%s is %vx%v, which is not a 4x3 cross of square faces",
			path, image.width, image.height)
		return {}, false
	}

	face := int(image.width / 4)

	// Column and row of each face in the cross, in the order the API numbers
	// the layers.
	cells := [6][2]int{
		{2, 1}, // +X
		{0, 1}, // -X
		{1, 0}, // +Y
		{1, 2}, // -Y
		{1, 1}, // +Z
		{3, 1}, // -Z
	}

	texture := create_gpu_cube_texture(i32(face))
	if texture == nil do return {}, false

	// One scratch face, refilled six times, rather than six allocations.
	pixels := make([][4]u8, face * face, context.temp_allocator)

	for cell, layer in cells {
		x0 := cell[0] * face
		y0 := cell[1] * face

		for y in 0 ..< face {
			source := (y0 + y) * int(image.width) + x0
			copy(pixels[y * face:][:face], image.pixels[source:][:face])
		}

		upload_texture_layer(texture, raw_data(pixels), i32(face), u32(layer))
	}

	skybox = Skybox{
		kind    = .CUBEMAP,
		texture = texture,
		sampler = mbi.renderer.skybox_clamp_sampler,
		tint    = WHITE,
	}

	return skybox, true
}

destroy_skybox :: proc(skybox: ^Skybox) {
	// The samplers belong to the renderer and are shared between every skybox,
	// so only the texture is this one's to give back.
	if skybox.texture != nil && mbi.renderer.device != nil {
		sdl.ReleaseGPUTexture(mbi.renderer.device, skybox.texture)
	}

	skybox^ = Skybox{}
}

// -----------------------------------------------------------------------
// Drawing
// -----------------------------------------------------------------------

/*
	Draws the sky behind everything else.

	Call it first, immediately after `begin_drawing_3d` and before any model. It
	neither tests nor writes depth, so whatever is drawn afterwards covers it --
	and calling it late would paint over the scene instead.

	The camera is the one `begin_drawing_3d` was given, and only its rotation is
	used. A sky is infinitely far away, so moving the camera does not move it,
	which is the whole reason this is a direction rather than geometry.
*/
draw_skybox :: proc(skybox: Skybox) {
	r := &mbi.renderer
	if !r.frame_active || r.pass == nil do return
	if skybox.texture == nil do return

	ensure(r.mode_3d, "draw_skybox must be called between begin_drawing_3d and end_drawing_3d")

	camera  := camera3d_defaults(r.camera3d)
	forward := camera3d_forward(camera)
	right   := camera3d_right(camera)

	// The camera's up squared to the other two, rather than the up it was
	// given: a camera may be handed an `up` that is not perpendicular to its
	// forward, and using that directly would shear the sky.
	up := cross3(right, forward)

	width  := f32(mbi.window_width)
	height := f32(mbi.window_height)

	aspect: f32 = 1
	if height > 0 do aspect = width / height

	/*
		Half the height of the view plane at unit distance, which is what turns
		a normalised device coordinate back into a direction.

		An orthographic camera has no such angle -- its `fov` is a height in
		world units, not degrees -- so it is given the perspective default
		instead. A sky drawn with no perspective is a single flat colour, which
		is never what was wanted.
	*/
	fov := camera.fov if camera.projection == .PERSPECTIVE else 70
	half := math.tan(math.to_radians(fov) * 0.5)

	vert_data := Skybox_Vert_Data{
		right   = {right.x * half * aspect, right.y * half * aspect, right.z * half * aspect, 0},
		up      = {up.x * half, up.y * half, up.z * half, 0},
		forward = {forward.x, forward.y, forward.z, 0},
	}

	frag_data := Mesh_Frag_Data{tint = skybox.tint}

	pipeline := r.pipelines.skybox_panorama
	if skybox.kind == .CUBEMAP do pipeline = r.pipelines.skybox_cubemap

	sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
	r.bound_pipeline = pipeline

	binding := sdl.GPUTextureSamplerBinding{texture = skybox.texture, sampler = skybox.sampler}
	sdl.BindGPUFragmentSamplers(r.pass, 0, &binding, 1)
	r.bound_texture = skybox.texture
	r.bound_sampler = skybox.sampler

	sdl.PushGPUVertexUniformData(r.cmd, 0, &vert_data, size_of(vert_data))
	sdl.PushGPUFragmentUniformData(r.cmd, 0, &frag_data, size_of(frag_data))

	// Three vertices and no buffers: the triangle is generated from
	// SV_VertexID. Nothing was bound, so the cache that tracks the shared quad
	// is told it is no longer current and left otherwise alone.
	r.bound_quad = false
	sdl.DrawGPUPrimitives(r.pass, 3, 1, 0, 0)
}

// Cross product, without reaching for linalg in a file that has no other use
// for it.
@(private)
cross3 :: proc(a, b: [3]f32) -> [3]f32 {
	return {
		a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z,
		a.x * b.y - a.y * b.x,
	}
}
