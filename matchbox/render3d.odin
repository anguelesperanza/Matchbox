package matchbox

/*
	Render -- 3D
	------------
	The second render pass, and everything that only exists inside it.

	**3D is a pass of its own rather than a change to the 2D one.** SDL3 bakes
	the target formats into a pipeline when it is created, so a pipeline built
	without a depth-stencil target cannot be used in a pass that has one. The
	five 2D pipelines were all built that way. Giving them depth would mean
	rebuilding every one of them and handing a game that draws nothing but
	sprites an 8MB depth buffer to go with it.

	So `begin_drawing_3d` closes whatever pass is open and starts one with depth
	attached; `end_drawing_3d` closes that, and the next 2D draw opens a
	colour-only pass through `ensure_pass` exactly as it always did. A frame is
	two or three passes instead of one, which costs nothing worth measuring.

	What it does mean is that the two cannot interleave for free. Scene, then
	HUD, pays one switch. Alternating them twenty times pays twenty.

	The depth buffer is created the first time a game asks for 3D, so a 2D-only
	program never allocates one.
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// Depth
// -----------------------------------------------------------------------

/*
	Makes sure there is a depth texture the size of the window.

	Recreated on resize rather than resized, because a GPU texture has no resize
	-- and released before the new one is made, since a window dragged from a
	corner produces one of these per frame of the drag.

	The format is asked for rather than assumed. `D24_UNORM_S8_UINT` is the one
	desktop drivers all have, `D32_FLOAT` is the usual fallback, and
	`D16_UNORM` is the one guaranteed everywhere -- which is the one an Android
	device may leave you with.
*/
@(private)
ensure_depth_texture :: proc() -> bool {
	r := &mbi.renderer
	if r.device == nil do return false

	width  := mbi.window_width
	height := mbi.window_height
	if width <= 0 || height <= 0 do return false

	if r.depth_texture != nil && r.depth_width == width && r.depth_height == height {
		return true
	}

	if r.depth_texture != nil {
		sdl.ReleaseGPUTexture(r.device, r.depth_texture)
		r.depth_texture = nil
	}

	if r.depth_format == .INVALID {
		r.depth_format = pick_depth_format()
	}

	r.depth_texture = sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = r.depth_format,
		usage                = {.DEPTH_STENCIL_TARGET},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})

	if r.depth_texture == nil {
		log.errorf("could not create a depth texture: %s", sdl.GetError())
		return false
	}

	r.depth_width  = width
	r.depth_height = height

	return true
}

// The best depth format this device will take. Settled once and remembered,
// because the pipeline has to be built against the same answer.
@(private)
pick_depth_format :: proc() -> sdl.GPUTextureFormat {
	candidates := [3]sdl.GPUTextureFormat{.D24_UNORM_S8_UINT, .D32_FLOAT, .D16_UNORM}

	for format in candidates {
		if sdl.GPUTextureSupportsFormat(mbi.renderer.device, format, .D2, {.DEPTH_STENCIL_TARGET}) {
			return format
		}
	}

	// Every backend SDL offers supports at least D16, so reaching this means
	// something is wrong enough that failing loudly is the kindness.
	log.error("no depth format is supported by this device")
	return .D16_UNORM
}

/*
	The same question as `pick_depth_format`, for a format this codebase had
	never needed until the shadow map: one written as a depth target in the
	shadow pass and *also* sampled as an ordinary texture in the main one.
	`D24_UNORM_S8_UINT`'s packed stencil byte is the more likely of the three
	to refuse that combination on a given backend, which is why it is tried
	last here rather than first as `pick_depth_format` tries it.
*/
@(private)
pick_shadow_format :: proc() -> sdl.GPUTextureFormat {
	candidates := [3]sdl.GPUTextureFormat{.D32_FLOAT, .D16_UNORM, .D24_UNORM_S8_UINT}

	for format in candidates {
		if sdl.GPUTextureSupportsFormat(mbi.renderer.device, format, .D2, {.DEPTH_STENCIL_TARGET, .SAMPLER}) {
			return format
		}
	}

	log.error("no format on this device supports a sampled depth texture; shadows will not work")
	return .D32_FLOAT
}

// -----------------------------------------------------------------------
// The 3D pass
// -----------------------------------------------------------------------

/*
	Opens the 3D pass and fixes the camera for everything drawn until
	`end_drawing_3d`.

	The colour target is loaded rather than cleared, so whatever
	`clear_background` put there is still underneath. Depth is cleared to 1 --
	the far plane -- every time, because last frame's depth is meaningless and
	keeping it would make this frame's geometry lose to it.

	Draw 2D after `end_drawing_3d`, not inside. A sprite drawn between these two
	would be handed to a pipeline that does not match the pass it is in, which
	is a validation error rather than a wrong picture.
*/
begin_drawing_3d :: proc(camera: Camera3D) {
	r := &mbi.renderer
	if !r.frame_active do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	depth_texture := current_depth_texture()
	if depth_texture == nil do return

	color := sdl.GPUColorTargetInfo{
		texture  = current_color_texture(),
		load_op  = .LOAD,
		store_op = .STORE,
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture     = depth_texture,
		clear_depth = 1,
		load_op     = .CLEAR,
		store_op    = .DONT_CARE, // nothing reads it after the pass ends
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, &color, 1, &depth)
	if r.pass == nil do return

	bind_cache_reset()
	apply_clip()

	r.mode_3d        = true
	r.view_projection = camera3d_view_projection(camera)
	r.camera3d        = camera

	// Once for the pass. The lights do not change between draws, and the camera
	// the shader needs for specular and fog is the one this pass was opened
	// with -- which the game should not have to hand over separately.
	push_lighting(camera)
}

// Closes the 3D pass. Anything drawn after this is 2D again, on top.
end_drawing_3d :: proc() {
	r := &mbi.renderer
	if !r.mode_3d do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	r.mode_3d = false
}

// Whether a 3D pass is open. `draw_model` checks it so that a model drawn
// outside one does nothing rather than recording into a pass that has no depth.
is_drawing_3d :: proc() -> bool {
	return mbi.renderer.mode_3d
}

// The camera the open 3D pass was started with.
current_camera3d :: proc() -> Camera3D {
	return mbi.renderer.camera3d
}

// -----------------------------------------------------------------------
// Drawing
// -----------------------------------------------------------------------

/*
	Draws every part of a model, placed by `transform` and multiplied by `tint`.

	One uniform push per part rather than per model, because a part is a draw
	call and the uniforms travel with it. The matrices are worked out once for
	the whole model, since all its parts share a transform.

	`animator` is the pose to draw a skinned model in, and is ignored by a model
	with no skeleton. Passing nil for one that has a skeleton draws it in its
	bind pose -- arms out, which is a legible "you forgot the animator" rather
	than a crash or an empty screen. A game with two characters sharing a model
	passes a different animator for each; see `animation3d.odin`.
*/
draw_model :: proc(
	model:     Model,
	transform: Transform,
	tint:      [4]f32 = WHITE,
	animator:  ^Animator = nil,
) {
	r := &mbi.renderer
	if !r.frame_active || r.pass == nil do return

	ensure(r.mode_3d || r.in_shadow_pass,
		"draw_model must be called between begin_drawing_3d/begin_shadow_pass and their matching end")

	model_matrix := transform_matrix(transform)

	// The light's view-projection in the shadow pass, the camera's everywhere
	// else -- the one thing that actually makes this the shadow pass rather
	// than an ordinary draw of the same geometry.
	view_projection := r.shadow.view_projection if r.in_shadow_pass else r.view_projection

	vert_data := Mesh_Vert_Data{
		mvp           = view_projection * model_matrix,
		model         = model_matrix,

		// Inverse transpose, so that a model scaled unevenly keeps its normals
		// square to its surfaces. For a uniform scale this is the model matrix
		// again and the work is wasted; for any other it is the difference
		// between lighting that follows the shape and lighting that slides off
		// it.
		normal_matrix = linalg.matrix4_inverse_transpose_f32(model_matrix),
	}

	frag_data := Mesh_Frag_Data{tint = tint}

	skin_data: Skin_Vert_Data

	for part, part_index in model.parts {
		if part.vertices == nil || part.indices == nil do continue

		// A grid or a wireframe has no faces for a shadow to fall across --
		// skipped here rather than given a line-topology shadow pipeline
		// nothing else needs.
		if r.in_shadow_pass && part.topology == .LINES do continue

		skinned  := part.skin >= 0
		textured := part.texture != nil

		// Per part rather than per model: a part says whether it is lines or
		// triangles, whether it has a texture, and whether a skeleton deforms
		// it, and between them those decide the pipeline. One loaded file
		// routinely holds parts that differ. The shadow pass only ever cares
		// about the skinned/unskinned half of that -- its fragment shader
		// writes nothing, so a textured part and an untextured one cast the
		// same shadow.
		pipeline := r.pipelines.mesh
		switch {
		case r.in_shadow_pass && skinned:     pipeline = r.pipelines.shadow_skinned
		case r.in_shadow_pass:                pipeline = r.pipelines.shadow
		case part.topology == .LINES:         pipeline = r.pipelines.line
		case skinned && textured:             pipeline = r.pipelines.mesh_skinned_textured
		case skinned:                         pipeline = r.pipelines.mesh_skinned
		case textured:                        pipeline = r.pipelines.mesh_textured
		}

		if r.bound_pipeline != pipeline {
			sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
			r.bound_pipeline = pipeline

			/*
				The shadow map, at whichever slot this pipeline's own
				fragment shader declares it -- 0 for the untextured
				pipelines, 1 for the textured ones, since SDL_GPU numbers a
				shader's sampled textures contiguously from t0 and
				mesh_textured's own albedo already occupies t0. See
				lighting.hlsli's comment on why the two shaders cannot agree
				on one fixed slot for it.

				Not bound at all in the shadow pass itself: that fragment
				shader samples nothing, so there is nothing here to give it.
			*/
			if !r.in_shadow_pass {
				shadow_binding := sdl.GPUTextureSamplerBinding{texture = r.shadow.texture, sampler = r.shadow.sampler}
				shadow_slot: u32 = 1 if textured else 0
				sdl.BindGPUFragmentSamplers(r.pass, shadow_slot, &shadow_binding, 1)

				// The pipeline switch just changed what slot 0 even means --
				// the shadow map a moment ago, on an untextured part, an
				// albedo texture now. Either way the cache below no longer
				// describes what is actually bound there.
				r.bound_texture = nil
				r.bound_sampler = nil
			}
		}

		if !r.in_shadow_pass && textured {
			sampler := part.sampler if part.sampler != nil else r.sprite_sampler

			if r.bound_texture != part.texture || r.bound_sampler != sampler {
				texture_binding := sdl.GPUTextureSamplerBinding{texture = part.texture, sampler = sampler}
				sdl.BindGPUFragmentSamplers(r.pass, 0, &texture_binding, 1)
				r.bound_texture = part.texture
				r.bound_sampler = sampler
			}
		}

		binding := sdl.GPUBufferBinding{buffer = part.vertices, offset = 0}
		sdl.BindGPUVertexBuffers(r.pass, 0, &binding, 1)
		sdl.BindGPUIndexBuffer(r.pass, {buffer = part.indices, offset = 0}, ._32BIT)

		// The shared quad is no longer what is bound, so the 2D cache has to be
		// told. Without this a sprite drawn in a later pass would skip its own
		// bind and draw a model's vertices through the sprite shader.
		r.bound_quad = false

		sdl.PushGPUVertexUniformData(r.cmd, 0, &vert_data, size_of(vert_data))

		// The shadow pass's fragment shader declares no uniform buffer at
		// all -- see shadow.frag.hlsl -- so there is nothing to push here.
		if !r.in_shadow_pass {
			sdl.PushGPUFragmentUniformData(r.cmd, 0, &frag_data, size_of(frag_data))
		}

		if skinned {
			joint_buffer: ^sdl.GPUBuffer

			if animator != nil && part_index < len(animator.pose.palettes) && animator.pose.joint_buffer != nil {
				joint_buffer = animator.pose.joint_buffer
			} else {
				/*
					No animator, or one with nothing skinned for this part --
					draw in the bind pose rather than reading whatever buffer a
					previous draw left bound, which would be a different
					character's palette or nothing at all. This is what makes a
					skinned model drawn without an animator come out arms-out
					rather than crashing or reading garbage: a joint matrix of
					identity leaves every vertex exactly where the file put it.
				*/
				joint_buffer = ensure_identity_joint_buffer(model.total_joints)
			}

			// Could not even allocate the identity fallback -- skip the part
			// rather than bind nothing and let the shader read undefined memory.
			if joint_buffer == nil do continue

			if r.bound_joint_buffer != joint_buffer {
				sdl.BindGPUVertexStorageBuffers(r.pass, 0, &joint_buffer, 1)
				r.bound_joint_buffer = joint_buffer
			}

			skin_data.joint_offset = part.joint_offset
			sdl.PushGPUVertexUniformData(r.cmd, 1, &skin_data, size_of(skin_data))
		}

		sdl.DrawGPUIndexedPrimitives(r.pass, part.index_count, 1, 0, 0, 0)
	}
}

/*
	The all-identity fallback for drawing a skinned model with no animator, or
	whose animator has nothing skinned for the part being drawn.

	Grown on demand and never shrunk: the common case is the same handful of
	rigs hitting this path over and over (in a finished game, usually none --
	this is the "you forgot the animator" path from draw_model's doc comment),
	so paying for one allocation the first time a model that big is drawn this
	way is cheaper than a fresh one on every such draw. `count` only ever needs
	to reach the biggest model drawn without an animator so far; the content is
	identity everywhere, so a smaller model reading into the tail of a buffer
	sized for a bigger one is still correct.
*/
@(private)
ensure_identity_joint_buffer :: proc(count: int) -> ^sdl.GPUBuffer {
	r := &mbi.renderer
	if count <= 0 do return nil
	if r.identity_joints != nil && r.identity_joints_count >= count do return r.identity_joints

	data := make([]matrix[4, 4]f32, count, context.temp_allocator)
	for i in 0 ..< count do data[i] = linalg.MATRIX4F32_IDENTITY

	buffer, err := upload_buffer(raw_data(data), u32(count) * size_of(matrix[4, 4]f32), {.GRAPHICS_STORAGE_READ})
	if err != nil {
		log.errorf("could not create the identity joint buffer: %v", err)
		return nil
	}

	if r.identity_joints != nil do sdl.ReleaseGPUBuffer(r.device, r.identity_joints)
	r.identity_joints       = buffer
	r.identity_joints_count = count

	return buffer
}

// A model at a position, at one scale on every axis and unturned. What most
// draws want, and the reason a game rarely has to build a Transform by hand.
draw_model_at :: proc(
	model:    Model,
	position: [3]f32,
	scale:    f32 = 1,
	tint:     [4]f32 = WHITE,
	animator: ^Animator = nil,
) {
	draw_model(model, create_transform(position, scale = scale), tint, animator)
}

/*
	Draws a model placed and turned about `pivot` rather than about its origin.

	`pivot` is a point in the model's own space, and `transform.position` is
	where that point ends up. `model_center(model)` is the usual argument;
	a body rig wants its eye height instead.

	**Why this exists.** `draw_model` places the origin, and a rigged model's
	origin is on the floor between its feet -- that is where an armature's root
	goes. Held at arm's length in first person that is fatal: `arms_rig.glb`
	carries its geometry 1.17 to 1.66 units *above* its origin, so placing the
	origin half a metre in front of the eye puts the arms a metre above the
	player's head, entirely outside the frustum. Nothing renders, nothing warns,
	and every plausible suspect -- facing, scale, the near plane -- is innocent.

	Scale is applied before the pivot is cancelled, so a model drawn at half size
	pivots about the same point on the mesh rather than about a point that has
	drifted half way to the origin.

	The alternative was a `pivot` field on `Transform`, and it was rejected:
	`Transform` is the argument to `draw_cube` and everything else spatial, so
	the field would be present and zero at nearly every construction site, and
	`transform_matrix` would silently start meaning something new for the callers
	that already build one by hand.
*/
draw_model_pivoted :: proc(
	model:     Model,
	pivot:     [3]f32,
	transform: Transform,
	tint:      [4]f32 = WHITE,
	animator:  ^Animator = nil,
) {
	draw_model(model, transform_pivoted(transform, pivot), tint, animator)
}

/*
	`transform` rewritten so that `pivot`, a point in model space, lands on
	`transform.position`.

	Its own procedure because two callers need the identical answer:
	`draw_model_pivoted` draws the model with it, and `node_world_matrix` places
	things on that model's bones with it. Worked out separately they would drift,
	and a weapon half a metre off the hand is a long way from an obvious cause.

	Scale is applied before the pivot is cancelled, matching `transform_matrix`,
	so a model drawn at half size pivots about the same point on the mesh rather
	than one that has slid toward the origin.
*/
@(private)
transform_pivoted :: proc(transform: Transform, pivot: [3]f32) -> Transform {
	t := transform
	t.position -= linalg.quaternion_mul_vector3(transform.rotation, pivot * transform.scale)
	return t
}
