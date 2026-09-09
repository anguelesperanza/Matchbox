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

	**Sampled as well as written since P7b**, which is a change to a resource
	every 3D game already has and so is worth saying out loud. SSAO and
	volumetric light both need to read this frame's depth back
	(`ssao.odin`), and under `FORWARD`/`CLUSTERED` there is nowhere else for
	it to come from -- `DEFERRED` has its own sampled depth target
	(`Gbuffer_Targets.depth`) and P6 deliberately built that as a second
	texture rather than widening this one, on the grounds that no
	forward/clustered game should pay for a feature only deferred used. That
	reasoning does not survive a feature every pipeline is meant to offer:
	the alternative would be a second full-size depth texture for
	forward/clustered as well, and the mesh pipelines cannot be bound in a
	pass whose depth format differs from the one they were built against
	(SDL3 bakes it in at creation), so that second texture would have to
	*replace* this one anyway.

	What it costs, stated rather than discovered: `pick_depth_format` now
	requires `{.DEPTH_STENCIL_TARGET, .SAMPLER}` of a candidate rather than
	`{.DEPTH_STENCIL_TARGET}` alone, so a device that offers
	`D24_UNORM_S8_UINT` only as a plain depth target now falls to
	`D32_FLOAT` -- `pick_shadow_format`'s own doc comment already flags that
	format as "the more likely of the three to refuse" a sampled
	combination. And on a tiled mobile GPU, a depth buffer that may be
	sampled generally cannot stay in tile memory. Neither is measurable
	here. The `store_op` is still `DONT_CARE` for a frame nothing reads the
	depth of, which is what keeps the second cost off a game that uses
	neither effect -- see `begin_drawing_3d`.
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
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
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
		if sdl.GPUTextureSupportsFormat(mbi.renderer.device, format, .D2, {.DEPTH_STENCIL_TARGET, .SAMPLER}) {
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
// Render pipeline dispatch
// -----------------------------------------------------------------------

/*
	`Render_Pipeline_Kind`'s own dispatcher, and the only place this file
	switches on it -- `lighting_rework.md` section 3.6 asks for
	`begin_drawing_3d`/`draw_model_immediate`/`end_drawing_3d` to "stop
	containing pipeline-specific code entirely" and dispatch instead; this
	pair, plus `pipeline_forward.odin`/`pipeline_clustered.odin`'s own tiny
	modules, is what that means in practice. Adding a third pipeline (P6's
	`DEFERRED`) touches one case in each of these two functions and its own
	new `pipeline_deferred.odin` -- nowhere else in this file.

	Called once, from `begin_drawing_3d`, after `push_lighting` has already
	pushed the camera-derived half of `Scene_Frag_Data` -- `CLUSTERED`'s own
	`pipeline_clustered_begin` needs the camera, not anything push_lighting
	computed from it, so the ordering is not load-bearing today, but it
	keeps "the scene's own state is current" true for whichever pipeline
	runs next regardless.
*/
@(private)
pipeline_begin_frame :: proc(camera: Camera3D) {
	switch mbi.renderer.lighting.settings.pipeline {
	case .CLUSTERED:
		pipeline_clustered_begin(camera)
	case .DEFERRED:
		pipeline_deferred_begin(camera)
	case .FORWARD:
		fallthrough
	case:
		pipeline_forward_begin(camera)
	}
}

/*
	The two cluster-only storage buffers `draw_model_immediate` binds every
	draw, whichever pipeline is actually running -- see this file's own doc
	comment on `pipeline_begin_frame` for why this is the dispatcher rather
	than an inline switch at the call site.
*/
@(private)
pipeline_cluster_buffers :: proc() -> (ranges, indices: ^sdl.GPUBuffer) {
	switch mbi.renderer.lighting.settings.pipeline {
	case .CLUSTERED:
		return pipeline_clustered_cluster_buffers()
	case .DEFERRED:
		return pipeline_deferred_cluster_buffers()
	case .FORWARD:
		fallthrough
	case:
		return pipeline_forward_cluster_buffers()
	}
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

	// Cleared first thing, not only where it is set below: every early return
	// between here and there would otherwise leave last frame's answer in
	// place, and a stale `true` makes draw_model and draw_skybox queue into a
	// frame that has no replay coming.
	r.scene_deferred = false
	if !r.frame_active do return

	// Whatever draw_model was asked to cast a shadow before either pass
	// existed, put into each active shadow map now -- a no-op per slot if
	// shadows are not enabled or nothing here is marked casts_shadow for
	// that slot, same as a game calling begin_shadow_pass by hand gets. The
	// same pending list goes into both maps: an occluder blocks whichever
	// light hits it, regardless of which slot that light landed in.
	if len(r.pending_shadow_models) > 0 {
		/*
			The directional/spot casters, through whichever of PCF/PCSS/
			CASCADED the scene picked -- CASCADED needs a pass per cascade
			per slot rather than one pass per slot, so it gets its own loop
			shape rather than sharing PCF/PCSS's. See Shadow_Technique's own
			doc comment for why CUBE (below, always attempted regardless of
			this switch) is not a case here at all.
		*/
		switch r.lighting.shadow.settings.technique {
		case .CASCADED:
			count := clamp(r.lighting.shadow.settings.cascade_count, 1, MAX_CASCADES)
			for slot in 0 ..< MAX_SHADOW_CASTERS {
				for cascade in 0 ..< count {
					if begin_cascade_shadow_pass(slot, cascade) {
						for pending in r.pending_shadow_models {
							draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
						}
						end_shadow_pass()
					}
				}
			}
		case .PCF, .PCSS:
			fallthrough
		case:
			for slot in 0 ..< MAX_SHADOW_CASTERS {
				if begin_shadow_pass(slot) {
					for pending in r.pending_shadow_models {
						draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
					}
					end_shadow_pass()
				}
			}
		}

		// The point-light caster, independent of whichever technique above
		// is running -- a no-op if shadows are off or no point light is
		// marked casts_shadow, the same "opt in twice, harmless otherwise"
		// shape the rest of this system already has.
		for face in 0 ..< 6 {
			if begin_point_shadow_pass(face) {
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

	/*
		DEFERRED opens its own G-buffer pass here instead -- see
		pipeline_deferred.odin's own top comment for the frame this
		pipeline actually runs and why it needs more than the one pass
		every other pipeline has always opened. The HDR target is still
		ensured just above regardless of which branch runs: DEFERRED's own
		final pass (pipeline_deferred_end, called from end_drawing_3d)
		needs it to already exist, the same way FORWARD/CLUSTERED already
		needed it here.
	*/
	/*
		P7b: a forward-family pipeline with SSAO on opens no pass at all here.
		Its scene has to go through a depth prepass and the AO pass before it
		can be shaded, and neither can start until the frame has said what its
		models are -- see `pipeline_forward_defers_scene`
		(pipeline_forward.odin). Everything below this point still runs:
		`mode_3d`, the camera, `push_lighting` and the per-pipeline begin all
		belong to the frame rather than to the pass, and holding them back
		would leave the queued draws with no camera to be replayed against.
	*/
	r.scene_deferred = pipeline_forward_defers_scene()
	clear(&r.pending_scene_models)

	switch {
	case r.scene_deferred:
		// Nothing to open yet. end_drawing_3d opens both passes, in order.

	case r.lighting.settings.pipeline == .DEFERRED:
		if !pipeline_deferred_open_gbuffer_pass() do return

	case:
		if !open_forward_scene_pass(load_depth = false) do return
	}

	r.mode_3d        = true
	r.view_projection = camera3d_view_projection(camera)
	r.camera3d        = camera

	// Once for the pass. The lights do not change between draws, and the camera
	// the shader needs for specular and fog is the one this pass was opened
	// with -- which the game should not have to hand over separately.
	push_lighting(camera)

	// Whichever Render_Pipeline_Kind is running gets to do its own per-frame
	// work here -- CLUSTERED rebuilds and reuploads its light lists for this
	// same camera; FORWARD has none. See pipeline_begin_frame's own doc
	// comment just above this file's "Render pipeline dispatch" section.
	pipeline_begin_frame(camera)
}

/*
	Opens the pass a forward-family pipeline shades into: the HDR scene target
	(`tonemap.odin`) and the frame's own depth buffer.

	Its own procedure since P7b, because there are now two moments it can
	happen at. Ordinarily it is `begin_drawing_3d`, exactly as it always was.
	With SSAO on it is `end_drawing_3d` instead, after the depth prepass and
	the AO pass have both run -- and then `load_depth` is true, so the pass
	keeps the depth the prepass already worked out rather than clearing it and
	making every fragment prove itself again. That is the early-Z half of what
	a prepass buys, and it is free once the prepass exists.

	`store_op` on the depth is the one thing here that is not fixed: nothing
	read this frame's depth after the pass ended until P7b, and nothing reads
	it now either unless something asked (`scene_depth_is_read`, ssao.odin).
	Kept as `DONT_CARE` in the common case rather than made unconditional,
	because a stored depth buffer is a real write on a tiled GPU where a
	discarded one never leaves tile memory -- see `ensure_depth_texture`'s own
	doc comment on what the `.SAMPLER` usage flag already costs there.
*/
@(private)
open_forward_scene_pass :: proc(load_depth: bool) -> bool {
	r := &mbi.renderer

	depth_texture := current_depth_texture()
	if depth_texture == nil do return false
	if r.lighting.targets.color == nil do return false

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
		load_op     = .LOAD if load_depth else .CLEAR,
		store_op    = .STORE if scene_depth_is_read() else .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, &color, 1, &depth)
	if r.pass == nil do return false

	bind_cache_reset()
	apply_clip()

	return true
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
	/*
		P7b's deferred-scene path, for a forward-family pipeline with SSAO on
		-- see `pipeline_forward_defers_scene` (pipeline_forward.odin) for why
		the whole frame was held back rather than drawn as it arrived.

		Three steps, and the order is the entire point: depth first, then the
		AO pass that reads it, then the scene pass that reads the AO. The sky
		goes in first once that pass is open, for the reason the pending
		shadow models are drawn last -- `draw_skybox`'s own pipeline writes no
		depth and relies on being first (see init.odin).
	*/
	if r.scene_deferred {
		r.scene_deferred = false

		if pipeline_forward_depth_prepass() {
			ssao_run(r.camera3d)
		}

		if !open_forward_scene_pass(load_depth = true) do return

		if r.has_pending_skybox {
			draw_skybox_immediate(r.pending_skybox)
			r.has_pending_skybox = false
			r.pending_skybox     = {}
		}
	}

	// The queue, replayed into whichever pass is now open -- ordinary draws
	// first, in submission order, exactly as they would have run had they not
	// been held. A frame that was never deferred has an empty list here.
	for pending in r.pending_scene_models {
		draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
	}
	clear(&r.pending_scene_models)

	for pending in r.pending_shadow_models {
		draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
	}
	clear(&r.pending_shadow_models)

	/*
		DEFERRED closes its own G-buffer pass and runs its own final pass
		here (the skybox it queued, the lighting quad, then the transparent/
		LINES parts it also queued) instead of the plain "close whatever is
		open" every other pipeline needed -- see pipeline_deferred.odin's
		own top comment.
	*/
	if r.lighting.settings.pipeline == .DEFERRED {
		pipeline_deferred_end()
	} else if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// Before the resolve, not after: bind_quad_state (inside resolve_tonemap)
	// asserts that 2D drawing never happens between begin_drawing_3d and
	// this call, and the resolve itself is 2D drawing -- a full-screen quad
	// through the ordinary bind_quad_state/push_quad path, not a 3D draw.
	r.mode_3d = false

	/*
		The post chain's earlier stages, between the last 3D draw and the
		resolve that ends the chain -- see post.odin's own top comment for
		what is in it and for the rule that decides whether a stage needs a
		pass of its own at all.

		Here rather than inside resolve_tonemap for the reason the ordering
		above already gives once: every stage in the chain opens render passes
		of its own into its own targets, and the resolve's own pass is the
		frame's, opened against current_color_texture(). Running the chain
		first means that pass is opened once, at the end, with everything it
		reads already finished.
	*/
	post_chain_run()

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
	if !r.frame_active do return

	ensure(r.mode_3d || r.in_shadow_pass,
		"draw_model must be called between begin_drawing_3d/begin_shadow_pass and their matching end")

	/*
		`FORWARD`/`CLUSTERED` with SSAO on have no pass open yet -- see
		`pipeline_forward_defers_scene` (pipeline_forward.odin) for why the
		scene cannot be drawn until its own depth has been through the AO
		pass first. The call is held here, in submission order, and
		`end_drawing_3d` replays it twice: once into the depth prepass, once
		into the real one.

		Before the `r.pass == nil` return below rather than after it, which is
		the whole subtlety: there genuinely is no pass at this moment, and the
		guard that exists to stop a stray draw from recording into nothing
		would otherwise silently swallow every model in the frame.
	*/
	if r.scene_deferred && !r.in_shadow_pass {
		append(&r.pending_scene_models, Pending_Shadow_Model{model, transform, tint, animator})
		return
	}

	if r.pass == nil do return

	// A shadow pass and a depth prepass want the identical thing from this
	// procedure: geometry into a depth buffer, with no material, no textures
	// and no fragment uniforms. They differ only in which matrix transforms
	// it, which is why the two flags stay separate and this local exists.
	depth_only := r.in_shadow_pass || r.in_depth_prepass

	/*
		DEFERRED's own routing -- see pipeline_deferred.odin's own top
		comment for the pass shape this exists to feed. `deferred_active` is
		true for every draw_model call made under DEFERRED outside a shadow
		pass, whether this is the ordinary "fill the G-buffer" call every
		game already makes or the later replay `pipeline_deferred_end`
		makes with `in_deferred_forward_pass` set once the final HDR pass is
		open.

		A part whose material is transparent, or whose topology is LINES,
		cannot go through the G-buffer at all (Material.transparent's own
		doc comment, material.odin -- a fill pass writes one material's
		worth of Surface fields per pixel, and LINES has no Surface-filling
		fragment shader in the first place, the plain flat mesh_line.frag.hlsl
		instead). The whole draw_model call is queued once, here, if it has
		any such part -- not per part, since the queue replays the entire
		call and lets the per-part switch below sort out which of its parts
		actually need drawing that second time.
	*/
	deferred_active := !depth_only && r.lighting.settings.pipeline == .DEFERRED

	if deferred_active && !r.in_deferred_forward_pass {
		needs_forward_fallback := false
		for part in model.parts {
			if part.topology == .LINES || part.material.transparent {
				needs_forward_fallback = true
				break
			}
		}
		if needs_forward_fallback {
			append(&r.pending_deferred_forward_models, Pending_Shadow_Model{model, transform, tint, animator})
		}
	}

	model_matrix := transform_matrix(transform)

	/*
		Whichever pass is being drawn into its own shadow map, the camera's
		everywhere else -- the one thing that actually makes this the shadow
		pass rather than an ordinary draw of the same geometry. Which array
		to read depends on which of the three pass shapes is currently open
		(`Shadow_State.active_kind`) -- PCF/PCSS's flat two slots, CASCADED's
		`[slot][cascade]`, or CUBE's `[face]` -- since each begin_*_shadow_pass
		leaves that field naming its own shape.
	*/
	shadow := &r.lighting.shadow
	view_projection := r.view_projection
	if r.in_shadow_pass {
		switch shadow.active_kind {
		case .CASCADE:
			view_projection = shadow.cascade_view_projections[shadow.active_slot][shadow.active_cascade]
		case .CUBE:
			view_projection = shadow.cube_view_projections[0][shadow.active_face]
		case .STANDARD:
			fallthrough
		case:
			view_projection = shadow.view_projections[shadow.active_slot]
		}
	}

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
		if depth_only && part.topology == .LINES do continue

		skinned := part.skin >= 0

		/*
			Whether this part fills the G-buffer (opaque, triangle-topology,
			drawn during the ordinary fill call) or is one the
			forward-fallback replay handles instead (transparent and/or
			LINES, drawn only once in_deferred_forward_pass is set) -- see
			draw_model_immediate's own top comment. A part that needs the
			replay is skipped outright the first time through, the mirror
			image of the continue two lines below skipping an already-filled
			part the second time through.
		*/
		is_deferred_fill := deferred_active && !r.in_deferred_forward_pass &&
			part.topology != .LINES && !part.material.transparent

		if deferred_active && r.in_deferred_forward_pass &&
			part.topology != .LINES && !part.material.transparent {
			continue // already drawn during the fill pass
		}

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
			shadow. `is_deferred_fill` picks DEFERRED's own pair
			(`gbuffer`/`gbuffer_skinned`) the identical way skinning already
			picks between `mesh`/`mesh_skinned`.
		*/
		pipeline := r.pipelines.mesh
		switch {
		case r.in_shadow_pass && skinned:   pipeline = r.pipelines.shadow_skinned
		case r.in_shadow_pass:              pipeline = r.pipelines.shadow
		case r.in_depth_prepass && skinned: pipeline = r.pipelines.depth_prepass_skinned
		case r.in_depth_prepass:            pipeline = r.pipelines.depth_prepass
		case part.topology == .LINES:     pipeline = r.pipelines.line
		case is_deferred_fill && skinned: pipeline = r.pipelines.gbuffer_skinned
		case is_deferred_fill:            pipeline = r.pipelines.gbuffer
		case skinned:                     pipeline = r.pipelines.mesh_skinned
		}

		if r.bound_pipeline != pipeline {
			sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
			r.bound_pipeline = pipeline
		}

		if !depth_only {
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
				Everything below is what `shade_surface` needs and
				`gbuffer.frag.hlsl` does not -- a G-buffer fill pass writes a
				`Surface`'s own values, it does not shade one (see that
				shader's own top comment), so none of the shadow maps, the
				probe, the light list or the cluster buffers are bound while
				`is_deferred_fill` is filling it. `deferred_lighting.frag.hlsl`
				binds its own copies of all of these itself, once per frame,
				in `draw_deferred_lighting_quad` (pipeline_deferred.odin) --
				this cache would not even help there, since that draw runs
				in a different pass than this one.
			*/
			if !is_deferred_fill {
				/*
					Every shadow technique's own maps -- PCF/PCSS's two at t4/t5,
					CASCADED's one Texture2DArray at t6, CUBE's one at t7 -- and
					the light list at t8 as a storage buffer, all scene-wide
					rather than per-part, so each of these four bind calls only
					fires when its own resource actually changed: the shadow
					textures when set_lighting rebuilds them, the light buffer
					when set_lights grows it past its previous capacity. A game
					calling either mid-pass, between draw_model calls, is what
					these cache checks are for -- see `bound_shadow_maps`/
					`bound_cascade_maps`/`bound_cube_maps`/`bound_light_buffer`'s
					own comment on `Renderer`.

					The slot numbers passed to BindGPUFragmentSamplers below (4,
					6, 7) track the HLSL t-register each group starts at, kept
					equal on purpose for readability -- but they need not be:
					BindGPUFragmentSamplers takes a slot within the *sampler*
					category alone (0 = base, 1-3 = the three material textures
					above, 4-7 = every shadow map), which SDL_GPU numbers
					separately from the storage-buffer category the light list
					binds into below. The two categories only share a numbering
					*inside the HLSL register(tN) declarations* -- see
					lighting_core.hlsli's own comment on `lights` for why -- so
					the light buffer's own BindGPUFragmentStorageBuffers call
					below still passes slot 0, unchanged, even though its own
					HLSL register moved again, from t20 down to t8, once P3b
					collapsed CASCADED's fourteen flat-map samplers (eight
					cascade, six cube) down to two Texture2DArray ones.
				*/
				if r.bound_shadow_maps != shadow.textures {
					shadow_bindings := [MAX_SHADOW_CASTERS]sdl.GPUTextureSamplerBinding{
						{texture = shadow.textures[0], sampler = shadow.sampler},
						{texture = shadow.textures[1], sampler = shadow.sampler},
					}
					sdl.BindGPUFragmentSamplers(r.pass, 4, &shadow_bindings[0], MAX_SHADOW_CASTERS)
					r.bound_shadow_maps = shadow.textures
				}

				/*
					CASCADED's array (slot 6) and CUBE's (slot 7) -- one
					GPUTextureSamplerBinding each, since P3b: both groups are one
					Texture2DArray apiece now (mesh.frag.hlsl's
					`cascade_maps`/`cube_maps`), not an HLSL resource array of
					flat `Texture2D`s needing one binding per layer. Always
					bound, whether or not `settings.technique` is actually
					CASCADED or a point light is actually casting a cube shadow
					this frame -- see Shadow_State's own doc comment for why the
					shared fragment shader cannot pick and choose which slots to
					declare.
				*/
				if r.bound_cascade_maps != shadow.cascade_texture {
					cascade_binding := sdl.GPUTextureSamplerBinding{texture = shadow.cascade_texture, sampler = shadow.sampler}
					sdl.BindGPUFragmentSamplers(r.pass, 6, &cascade_binding, 1)
					r.bound_cascade_maps = shadow.cascade_texture
				}

				if r.bound_cube_maps != shadow.cube_texture {
					cube_binding := sdl.GPUTextureSamplerBinding{texture = shadow.cube_texture, sampler = shadow.sampler}
					sdl.BindGPUFragmentSamplers(r.pass, 7, &cube_binding, 1)
					r.bound_cube_maps = shadow.cube_texture
				}

				/*
					The environment probe's own two maps, slots 8 and 9 -- one
					`default_probe_texture` placeholder standing in for whichever
					half (or both) `Renderer.lighting.probe` does not currently
					have, the same "always something valid bound" shape every
					other always-declared slot in this shader already has. Bound
					as a pair, unlike the shadow slots above, since a game
					replacing its probe (`set_environment_probe`, ambient.odin)
					always replaces both maps together -- there is no technique
					switch here that leaves one stale while the other updates.
				*/
				probe_maps := [2]^sdl.GPUTexture{
					r.lighting.probe.irradiance  if r.lighting.probe.irradiance  != nil else r.default_probe_texture,
					r.lighting.probe.prefiltered if r.lighting.probe.prefiltered != nil else r.default_probe_texture,
				}
				if r.bound_probe_maps != probe_maps {
					probe_bindings := [2]sdl.GPUTextureSamplerBinding{
						{texture = probe_maps[0], sampler = r.linear_clamp_sampler},
						{texture = probe_maps[1], sampler = r.linear_clamp_sampler},
					}
					sdl.BindGPUFragmentSamplers(r.pass, 8, &probe_bindings[0], 2)
					r.bound_probe_maps = probe_maps
				}

				/*
					P7b's ambient occlusion, slot 10 -- `Renderer.default_texture`
					(1x1 **white**) whenever SSAO is off or its pass did not run,
					since this is a factor and the identity of a factor is one.
					The same always-something-valid-bound shape every slot above
					it has; see `ssao_output`'s own doc comment (ssao.odin) for
					why white rather than the black placeholder the probe slots
					use.
				*/
				ssao_texture := ssao_output()
				if ssao_texture == nil do ssao_texture = r.default_texture

				if r.bound_ssao_map != ssao_texture {
					ssao_binding := sdl.GPUTextureSamplerBinding{texture = ssao_texture, sampler = r.linear_clamp_sampler}
					sdl.BindGPUFragmentSamplers(r.pass, 10, &ssao_binding, 1)
					r.bound_ssao_map = ssao_texture
				}

				if r.bound_light_buffer != r.lighting.light_buffer {
					light_buffer := r.lighting.light_buffer
					sdl.BindGPUFragmentStorageBuffers(r.pass, 0, &light_buffer, 1)
					r.bound_light_buffer = light_buffer
				}

				/*
					CLUSTERED's own two storage buffers (slots 1/2, HLSL t11/t12
					-- lighting_core.hlsli's own comment), or FORWARD's
					placeholders for the same slots -- pipeline_cluster_buffers
					(this file's own "Render pipeline dispatch" section) is the
					one place that decides which, so this stays a plain bind-if-
					changed the same shape every other resource in this function
					already has, rather than a pipeline switch of its own.
				*/
				cluster_ranges, cluster_light_indices := pipeline_cluster_buffers()

				if r.bound_cluster_ranges != cluster_ranges {
					buffer := cluster_ranges
					sdl.BindGPUFragmentStorageBuffers(r.pass, 1, &buffer, 1)
					r.bound_cluster_ranges = cluster_ranges
				}

				if r.bound_cluster_light_indices != cluster_light_indices {
					buffer := cluster_light_indices
					sdl.BindGPUFragmentStorageBuffers(r.pass, 2, &buffer, 1)
					r.bound_cluster_light_indices = cluster_light_indices
				}
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
		if !depth_only {
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
