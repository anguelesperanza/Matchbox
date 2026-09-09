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

	**The colour target is not the game's own destination, since P1.** The
	pass below writes into an internal HDR scene target
	(`Renderer.lighting.targets`, `tonemap.odin`) rather than whatever
	`current_color_texture()` names; `end_drawing_3d` resolves that target
	through the tonemap curve and the gamma encode and writes the result,
	opaque, over the window or a game's own `Render_Target` -- see
	`tonemap.odin`'s own top comment for why the format has to be internal at
	all, and `lighting_rework.md` section 3.7 for the consequences that
	forced it.
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

	**The colour target is cleared, not loaded, since P1.** Before the HDR
	resolve existed, this loaded whatever `clear_background` had just painted
	onto the real destination, so that background showed through underneath
	the 3D geometry. The pass now opens against the internal HDR scene target
	instead (`ensure_hdr_texture`, tonemap.odin), and a target that has never
	been drawn into this frame has nothing meaningful to load -- so it is
	cleared instead, to the last colour `clear_background` was given
	(`Renderer.background_color`), converted to linear
	(`linearize_background_color`) since everything else reaching this target
	is linear light too. `end_drawing_3d` resolves the finished target back
	onto the real destination afterward.

	This changes behaviour for exactly one pattern: a game that draws 2D
	*before* `begin_drawing_3d` and relies on it showing through the 3D pass
	the old load contract preserved. Checked by hand across every example in
	this repository (`cube`, `skybox`, `third-person`, `model`, `primitives`,
	`first-person`, `animation-layers`, `post`, `lighting` -- the only ones
	that call `begin_drawing_3d` at all): every one of them calls
	`clear_background` immediately beforehand with nothing 2D drawn in
	between, so none relied on it. A game that does draw 2D there today would
	see that content disappear under the 3D pass rather than show through it.

	Depth is cleared to 1 -- the far plane -- every time, because last frame's
	depth is meaningless and keeping it would make this frame's geometry lose
	to it.

	Draw 2D after `end_drawing_3d`, not inside. A sprite drawn between these two
	would be handed to a pipeline that does not match the pass it is in, which
	is a validation error rather than a wrong picture.
*/
begin_drawing_3d :: proc(camera: Camera3D) {
	r := &mbi.renderer
	if !r.frame_active do return

	// Whatever draw_model was asked to cast a shadow before either pass
	// existed, put into each active shadow map now -- a no-op per slot if
	// shadows are not enabled or nothing here is marked casts_shadow for
	// that slot, same as a game calling begin_shadow_pass by hand gets. The
	// same pending list goes into both maps: an occluder blocks whichever
	// light hits it, regardless of which slot that light landed in.
	if len(r.pending_shadow_models) > 0 {
		for slot in 0 ..< MAX_SHADOW_CASTERS {
			if begin_shadow_pass(slot) {
				for pending in r.pending_shadow_models {
					draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
				}
				end_shadow_pass()
			}
		}
	}

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	depth_texture := current_depth_texture()
	if depth_texture == nil do return
	if !ensure_hdr_texture() do return

	linear_background := linearize_background_color(r.background_color)

	color := sdl.GPUColorTargetInfo{
		texture     = r.lighting.targets.color,
		clear_color = {linear_background.x, linear_background.y, linear_background.z, linear_background.w},
		load_op     = .CLEAR,
		store_op    = .STORE,
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

/*
	Closes the 3D pass and resolves it. Anything drawn after this is 2D
	again, on top.

	The resolve (`resolve_tonemap`, tonemap.odin) runs here rather than
	inside `begin_drawing_3d` of the *next* frame's pass, because the HDR
	target's content is only complete once every draw between the matching
	`begin_drawing_3d` and this call has happened -- tone mapping a
	half-drawn scene would tonemap whatever was there minus whatever came
	after this call had already run.
*/
end_drawing_3d :: proc() {
	r := &mbi.renderer
	if !r.mode_3d do return

	/*
		The other half of what the shadow pass drew, into the scene itself --
		held until now rather than drawn the moment the pass opened, because
		draw_skybox's own pipeline writes no depth at all and relies on being
		first: see its "drawn first, so everything after it covers it" comment
		in init.odin. Drawing these where begin_drawing_3d used to would put
		them before a skybox the game draws afterward, and the skybox would
		paint over them with nothing to stop it. Last is always safe, since
		everything else here does write depth.
	*/
	for pending in r.pending_shadow_models {
		draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
	}
	clear(&r.pending_shadow_models)

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// Before the resolve, not after: draw_quad (inside resolve_tonemap)
	// asserts that 2D drawing never happens between begin_drawing_3d and
	// this call, and the resolve itself is 2D drawing -- a full-screen quad
	// through the ordinary bind_quad_state/push_quad path, not a 3D draw.
	r.mode_3d = false

	resolve_tonemap()
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

// One draw_model call, held on to until begin_drawing_3d has a pass open to
// put it in. See draw_model's own doc comment on casts_shadow.
Pending_Shadow_Model :: struct {
	model:     Model,
	transform: Transform,
	tint:      [4]f32,
	animator:  ^Animator,
}

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

	**`casts_shadow`** is the one case this is called *outside* begin_drawing_3d
	or begin_shadow_pass rather than between one and its matching end. Marked
	true, the call is held rather than drawn immediately; begin_drawing_3d puts
	it in both passes for you -- once into the shadow map, once into the scene
	-- so a caller no longer hand-draws the same model twice to get both. Left
	false, this draws immediately exactly as it always has, and still needs to
	run inside a pass of one kind or another.
*/
draw_model :: proc(
	model:        Model,
	transform:    Transform,
	tint:         [4]f32 = WHITE,
	animator:     ^Animator = nil,
	casts_shadow: bool = false,
) {
	r := &mbi.renderer

	if casts_shadow && !r.mode_3d && !r.in_shadow_pass {
		append(&r.pending_shadow_models, Pending_Shadow_Model{model, transform, tint, animator})
		return
	}

	draw_model_immediate(model, transform, tint, animator)
}

@(private)
draw_model_immediate :: proc(
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

	// Whichever slot's light is being drawn into its shadow map, the
	// camera's everywhere else -- the one thing that actually makes this the
	// shadow pass rather than an ordinary draw of the same geometry.
	shadow := &r.lighting.shadow
	view_projection := shadow.view_projections[shadow.active_slot] if r.in_shadow_pass else r.view_projection

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

	skin_data: Skin_Vert_Data

	for part, part_index in model.parts {
		if part.vertices == nil || part.indices == nil do continue

		// A grid or a wireframe has no faces for a shadow to fall across --
		// skipped here rather than given a line-topology shadow pipeline
		// nothing else needs.
		if r.in_shadow_pass && part.topology == .LINES do continue

		skinned := part.skin >= 0

		/*
			Per part rather than per model: a part says whether it is lines or
			triangles and whether a skeleton deforms it, and between them
			those decide the pipeline. One loaded file routinely holds parts
			that differ. Whether a part carries a texture no longer picks a
			pipeline at all -- `mesh`/`mesh_skinned` share one fragment shader
			for textured and untextured parts alike (see `mesh.frag.hlsl` and
			`Shaders.mesh_frag`'s own comment), so what used to be four mesh
			pipelines is two. The shadow pass only ever cares about the
			skinned/unskinned half of this -- its fragment shader writes
			nothing, so a textured part and an untextured one cast the same
			shadow.
		*/
		pipeline := r.pipelines.mesh
		switch {
		case r.in_shadow_pass && skinned: pipeline = r.pipelines.shadow_skinned
		case r.in_shadow_pass:            pipeline = r.pipelines.shadow
		case part.topology == .LINES:     pipeline = r.pipelines.line
		case skinned:                     pipeline = r.pipelines.mesh_skinned
		}

		if r.bound_pipeline != pipeline {
			sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
			r.bound_pipeline = pipeline
		}

		if !r.in_shadow_pass {
			/*
				Base colour at t0, always -- the 1x1 white default whenever
				the part has none of its own, per `mesh.frag.hlsl`'s own
				collapse of what used to be two shaders. Slot numbering no
				longer depends on the pipeline the way it did before this
				rework, so this does not need redoing on a pipeline switch
				the way the old shadow-map binding below used to.
			*/
			base    := part.material.textures.base    if part.material.textures.base    != nil else r.default_texture
			sampler := part.material.textures.base_sampler if part.material.textures.base_sampler != nil else r.sprite_sampler

			if r.bound_texture != base || r.bound_sampler != sampler {
				texture_binding := sdl.GPUTextureSamplerBinding{texture = base, sampler = sampler}
				sdl.BindGPUFragmentSamplers(r.pass, 0, &texture_binding, 1)
				r.bound_texture = base
				r.bound_sampler = sampler
			}

			/*
				Metallic-roughness, occlusion and emissive at t1-t3 -- the
				same 1x1 white default as base whenever a part's material
				carries none of its own. White is the right stand-in for all
				three, the same reasoning as base colour's: every one of
				these is read as factor * texture (mesh.frag.hlsl), so the
				identity value for a missing texture is 1.0 in every channel,
				not 0. Getting this backwards for emissive specifically would
				be easy and wrong in a way nothing would flag -- a black
				default would silently zero out any material that sets an
				emissive *factor* with no emissive texture at all, which is
				every emissive material `create_material_pbr_metallic` builds
				today (its own textures default to {}).
			*/
			material_textures := [3]^sdl.GPUTexture{
				part.material.textures.metal_rough if part.material.textures.metal_rough != nil else r.default_texture,
				part.material.textures.occlusion   if part.material.textures.occlusion   != nil else r.default_texture,
				part.material.textures.emissive    if part.material.textures.emissive    != nil else r.default_texture,
			}

			if r.bound_material_textures != material_textures {
				bindings := [3]sdl.GPUTextureSamplerBinding{
					{texture = material_textures[0], sampler = r.sprite_sampler},
					{texture = material_textures[1], sampler = r.sprite_sampler},
					{texture = material_textures[2], sampler = r.sprite_sampler},
				}
				sdl.BindGPUFragmentSamplers(r.pass, 1, &bindings[0], 3)
				r.bound_material_textures = material_textures
			}

			/*
				The two shadow maps at t4/t5, and the light list at t6 as a
				storage buffer -- both scene-wide rather than per-part, so
				this only rebinds when either actually changed: the shadow
				maps when set_lighting rebuilds them, the light buffer when
				set_lights grows it past its previous capacity. A game
				calling either mid-pass, between draw_model calls, is what
				this cache check is for -- see `bound_shadow_maps`/
				`bound_light_buffer`'s own comment on `Renderer`.

				Slot 4 here, not t4 -- BindGPUFragmentSamplers takes a slot
				within the *sampler* category alone (0 = base, 1-3 = the
				three material textures just above, 4-5 = these two), which
				SDL_GPU numbers separately from the storage-buffer category
				the light list below binds into. The two categories only
				share a numbering *inside the HLSL register(tN) declarations*
				-- see lighting_core.hlsli's own comment on `lights` for why
				-- so the light buffer's own BindGPUFragmentStorageBuffers
				call below still passes slot 0, unchanged, even though its
				HLSL register moved from t3 to t6 to make room for the three
				new samplers.
			*/
			if r.bound_shadow_maps != shadow.textures {
				shadow_bindings := [MAX_SHADOW_CASTERS]sdl.GPUTextureSamplerBinding{
					{texture = shadow.textures[0], sampler = shadow.sampler},
					{texture = shadow.textures[1], sampler = shadow.sampler},
				}
				sdl.BindGPUFragmentSamplers(r.pass, 4, &shadow_bindings[0], MAX_SHADOW_CASTERS)
				r.bound_shadow_maps = shadow.textures
			}

			if r.bound_light_buffer != r.lighting.light_buffer {
				light_buffer := r.lighting.light_buffer
				sdl.BindGPUFragmentStorageBuffers(r.pass, 0, &light_buffer, 1)
				r.bound_light_buffer = light_buffer
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
		// Built per part rather than once for the whole model: the material
		// (shading model, base colour, specular power, ...) is a part's own,
		// only `tint` is the same for every part of this draw_model call.
		if !r.in_shadow_pass {
			frag_data := material_frag_data(part.material, tint)
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
	model:        Model,
	position:     [3]f32,
	scale:        f32 = 1,
	tint:         [4]f32 = WHITE,
	animator:     ^Animator = nil,
	casts_shadow: bool = false,
) {
	draw_model(model, create_transform(position, scale = scale), tint, animator, casts_shadow)
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
