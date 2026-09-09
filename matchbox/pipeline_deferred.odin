package matchbox

import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	Render pipeline -- deferred
	-----------------------------
	`Render_Pipeline_Kind.DEFERRED`'s own half of the dispatch
	(`pipeline_begin_frame`/`pipeline_cluster_buffers`, render3d.odin), plus
	the pass orchestration `FORWARD`/`CLUSTERED` never needed -- both of
	those run every draw inside the one 3D pass `begin_drawing_3d` opens and
	`end_drawing_3d` closes. `DEFERRED` cannot: a G-buffer fill pass and the
	pass that shades it are necessarily two separate `BeginGPURenderPass`
	calls (different colour targets, a transparent part cannot go through
	either at all), so this file is also where `begin_drawing_3d`/
	`draw_model_immediate`/`end_drawing_3d` (render3d.odin) branch out to,
	the same "one switch, everywhere else stays ignorant" shape those three
	already keep for `FORWARD` vs `CLUSTERED`.

	**The frame, as this pipeline actually runs it:**

	1. `begin_drawing_3d` opens the G-buffer pass instead of the HDR one
	   (`pipeline_deferred_open_gbuffer_pass`) -- four `R16G16B16A16_FLOAT`
	   targets (`Gbuffer_Targets`, gbuffer.odin) plus this pipeline's own
	   depth texture, GB_B's own `shading_model` channel cleared to
	   `GBUFFER_EMPTY` (shaders/gbuffer.hlsli) so a lighting pass later
	   knows which pixels nothing ever drew into.
	2. Every `draw_model` call in between fills the G-buffer for its opaque,
	   triangle-topology parts (`r.pipelines.gbuffer`/`gbuffer_skinned`,
	   `gbuffer.frag.hlsl`) -- see `draw_model_immediate`'s own doc comment
	   on `Renderer.in_deferred_forward_pass` for what happens to a
	   transparent or LINES-topology part instead: it cannot go into this
	   pass at all, so the whole call is queued
	   (`Renderer.pending_deferred_forward_models`) rather than drawn now.
	   `draw_skybox` is queued the identical way (`Renderer.pending_skybox`)
	   for the identical reason -- its own pipelines are built for the HDR
	   target's one colour format, not the G-buffer's four.
	3. `end_drawing_3d` closes the G-buffer pass and calls
	   `pipeline_deferred_end`, which opens one more pass -- colour the HDR
	   scene target (cleared, same as `FORWARD`'s own single pass always
	   was), depth `Renderer.depth_texture` (the *ordinary* shared depth,
	   not the G-buffer's own) -- and, in order:
	     a. the queued skybox, through its own unmodified pipeline;
	     b. `deferred_lighting`'s own fullscreen quad
	        (`draw_deferred_lighting_quad`, `deferred_lighting.frag.hlsl`),
	        which decodes the G-buffer back into a `Surface` and calls the
	        identical `shade_surface` a forward draw would have, discarding
	        (rather than shading) every pixel GB_B's own sentinel says
	        nothing was ever drawn into -- which is what lets step (a)'s sky
	        show through rather than being painted over;
	     c. the queued transparent/LINES draws, through the *ordinary*
	        forward `mesh`/`mesh_skinned`/`line` pipelines, exactly as
	        `FORWARD` already draws them.
	   `resolve_tonemap` (tonemap.odin) then runs unchanged, over whatever
	   this pass just finished compositing.

	**The one accepted gap, stated rather than hidden**: step 3c's own depth
	attachment is `Renderer.depth_texture`, cleared to the far plane at the
	top of that same pass -- not the G-buffer's own depth, which already
	holds every opaque surface's real distance. A transparent object or a
	wireframe therefore depth-tests and depth-writes correctly *against
	itself and against other transparent/LINES draws in the same pass*, but
	is never occluded by opaque G-buffer geometry that should hide it. Two
	textures rather than one is the deliberate trade: the G-buffer's own
	depth format is picked for being safely *sampled* (`pick_shadow_format`,
	same combination-of-usages caution `Shadow_State.format` already needed
	-- see `Gbuffer_Targets`' own doc comment, gbuffer.odin), which
	`Renderer.depth_format` (`pick_depth_format`, render3d.odin) was never
	asked to guarantee and this phase does not risk changing for every
	forward/clustered game to find out. Fixing this properly needs either a
	guaranteed-sampled `Renderer.depth_texture` (a change with its own,
	unmeasurable risk to every existing pipeline built against it) or a
	second family of forward/line/skybox pipelines built against the
	G-buffer's own depth format -- both real, neither attempted this phase.
	Worth revisiting if a game that mixes DEFERRED with real transparency
	against opaque occluders turns out to need it; nothing here has that
	scene, and there is no GPU in this environment to see the seam even if
	one did.
*/

// Nothing to build before the G-buffer pass opens -- the pass itself is
// already open by the time this runs (pipeline_begin_frame is called after
// begin_drawing_3d has opened whichever pass its own pipeline needs), and
// pipeline_deferred_open_gbuffer_pass below is what ensures the G-buffer's
// own targets exist. The same "nothing per-frame beyond what already
// happened" shape pipeline_forward_begin (pipeline_forward.odin) has.
@(private)
pipeline_deferred_begin :: proc(camera: Camera3D) {
}

// FORWARD's own placeholders -- DEFERRED's lighting pass loops the whole
// light list (lighting_core.hlsli's own shade_lights, the branch this
// phase's own RENDER_PIPELINE_CLUSTERED fix keeps DEFERRED out of), so it
// never reads either buffer, the identical "opt in, nothing happens" shape
// pipeline_forward_cluster_buffers already has.
@(private)
pipeline_deferred_cluster_buffers :: proc() -> (ranges, indices: ^sdl.GPUBuffer) {
	return mbi.renderer.default_cluster_ranges_buffer, mbi.renderer.default_cluster_light_indices_buffer
}

/*
	Opens the G-buffer pass -- called from `begin_drawing_3d` instead of
	that function's own ordinary HDR-pass-opening code, once
	`Lighting_Settings.pipeline == .DEFERRED`.

	GB_B's own clear colour puts `GBUFFER_EMPTY` in the one channel
	(`z`, `shading_model`) `deferred_lighting.frag.hlsl` actually reads to
	decide whether anything was ever drawn here -- see `shaders/gbuffer.hlsli`'s
	own top comment. The other three targets clear to all-zero, which is
	never inspected for any pixel the lighting pass discards.

	This pipeline's own depth (`Gbuffer_Targets.depth`) stores rather than
	discards (`store_op = .STORE`): `deferred_lighting.frag.hlsl` samples it
	back, once the pass has closed, to reconstruct `Surface.position` -- see
	that shader's own top comment.
*/
@(private)
pipeline_deferred_open_gbuffer_pass :: proc() -> bool {
	r := &mbi.renderer
	if !ensure_gbuffer_targets() do return false

	g := &r.lighting.gbuffer

	colors := [4]sdl.GPUColorTargetInfo{
		{texture = g.a, clear_color = {0, 0, 0, 0}, load_op = .CLEAR, store_op = .STORE},
		{texture = g.b, clear_color = {0, 0, GBUFFER_EMPTY, 0}, load_op = .CLEAR, store_op = .STORE},
		{texture = g.c, clear_color = {0, 0, 0, 0}, load_op = .CLEAR, store_op = .STORE},
		{texture = g.d, clear_color = {0, 0, 0, 0}, load_op = .CLEAR, store_op = .STORE},
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = g.depth,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .STORE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, &colors[0], 4, &depth)
	if r.pass == nil do return false

	bind_cache_reset()
	apply_clip()

	return true
}

/*
	Closes the G-buffer pass and runs everything the final HDR pass needs --
	called from `end_drawing_3d` in place of that function's own ordinary
	"close whatever pass is open" line, once `Lighting_Settings.pipeline ==
	.DEFERRED`. See this file's own top comment for the three things drawn
	into the pass this opens, in order, and why that order is load-bearing
	(the sky has to be down first for the lighting quad's own discard to
	leave it showing through, and the lighting quad has to run before the
	transparent/LINES flush so those draw over an already-lit scene the way
	forward transparency always has).
*/
@(private)
pipeline_deferred_end :: proc() {
	r := &mbi.renderer

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	depth_texture := current_depth_texture()
	if depth_texture == nil do return

	linear_background := linearize_background_color(r.background_color)

	color := sdl.GPUColorTargetInfo{
		texture     = r.lighting.targets.color,
		clear_color = {linear_background.x, linear_background.y, linear_background.z, linear_background.w},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = depth_texture,
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, &color, 1, &depth)
	if r.pass == nil do return

	bind_cache_reset()
	apply_clip()

	if r.has_pending_skybox {
		draw_skybox_immediate(r.pending_skybox)
		r.has_pending_skybox = false
		r.pending_skybox = {}
	}

	draw_deferred_lighting_quad()

	// Replayed with in_deferred_forward_pass set, so draw_model_immediate's
	// own per-part switch draws only the transparent/LINES parts that could
	// not go through the G-buffer -- see that proc's own doc comment.
	r.in_deferred_forward_pass = true
	for pending in r.pending_deferred_forward_models {
		draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
	}
	r.in_deferred_forward_pass = false
	clear(&r.pending_deferred_forward_models)

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}
}

/*
	The G-buffer's own uniform -- see `Deferred_Lighting_Frag_Data`'s own
	doc comment (this file) for what it carries and why.
*/
@(private)
draw_deferred_lighting_quad :: proc() {
	r      := &mbi.renderer
	g      := &r.lighting.gbuffer
	shadow := &r.lighting.shadow

	pipeline := r.pipelines.deferred_lighting
	sdl.BindGPUGraphicsPipeline(r.pass, pipeline)
	r.bound_pipeline = pipeline

	// t0-t3, the four G-buffer targets -- see deferred_lighting.frag.hlsl's
	// own top comment for the register map this mirrors. The nearest
	// sampler, not linear: this quad is always exactly the size of the
	// targets it reads (both are sized by get_current_target_size,
	// gbuffer.odin/tonemap.odin), the same reasoning resolve_tonemap
	// (tonemap.odin) already gives for using sprite_sampler here too.
	gbuffer_bindings := [4]sdl.GPUTextureSamplerBinding{
		{texture = g.a, sampler = r.sprite_sampler},
		{texture = g.b, sampler = r.sprite_sampler},
		{texture = g.c, sampler = r.sprite_sampler},
		{texture = g.d, sampler = r.sprite_sampler},
	}
	sdl.BindGPUFragmentSamplers(r.pass, 0, &gbuffer_bindings[0], 4)

	// t4, this pipeline's own depth -- plain sampled, not a comparison
	// sampler, since this is read as "what depth is here" rather than "is
	// this point in shadow".
	depth_binding := sdl.GPUTextureSamplerBinding{texture = g.depth, sampler = r.sprite_sampler}
	sdl.BindGPUFragmentSamplers(r.pass, 4, &depth_binding, 1)

	// t5-t10, mirroring mesh.frag.hlsl's own t4-t9 exactly -- see
	// draw_model_immediate's own comment on the identical bindings for why
	// these slot numbers are BindGPUFragmentSamplers' own sampler-category
	// index rather than the literal t-register.
	shadow_bindings := [MAX_SHADOW_CASTERS]sdl.GPUTextureSamplerBinding{
		{texture = shadow.textures[0], sampler = shadow.sampler},
		{texture = shadow.textures[1], sampler = shadow.sampler},
	}
	sdl.BindGPUFragmentSamplers(r.pass, 5, &shadow_bindings[0], MAX_SHADOW_CASTERS)

	cascade_binding := sdl.GPUTextureSamplerBinding{texture = shadow.cascade_texture, sampler = shadow.sampler}
	sdl.BindGPUFragmentSamplers(r.pass, 7, &cascade_binding, 1)

	cube_binding := sdl.GPUTextureSamplerBinding{texture = shadow.cube_texture, sampler = shadow.sampler}
	sdl.BindGPUFragmentSamplers(r.pass, 8, &cube_binding, 1)

	probe_maps := [2]^sdl.GPUTexture{
		r.lighting.probe.irradiance  if r.lighting.probe.irradiance  != nil else r.default_probe_texture,
		r.lighting.probe.prefiltered if r.lighting.probe.prefiltered != nil else r.default_probe_texture,
	}
	probe_bindings := [2]sdl.GPUTextureSamplerBinding{
		{texture = probe_maps[0], sampler = r.probe_sampler},
		{texture = probe_maps[1], sampler = r.probe_sampler},
	}
	sdl.BindGPUFragmentSamplers(r.pass, 9, &probe_bindings[0], 2)

	light_buffer := r.lighting.light_buffer
	sdl.BindGPUFragmentStorageBuffers(r.pass, 0, &light_buffer, 1)

	cluster_ranges, cluster_light_indices := pipeline_cluster_buffers()
	ranges_buf  := cluster_ranges
	indices_buf := cluster_light_indices
	sdl.BindGPUFragmentStorageBuffers(r.pass, 1, &ranges_buf, 1)
	sdl.BindGPUFragmentStorageBuffers(r.pass, 2, &indices_buf, 1)

	// The one uniform this shader owns that mesh.frag.hlsl has no need of --
	// see Deferred_Lighting_Frag_Data's own doc comment (this file) and
	// gbuffer.hlsli's top comment on why position is reconstructed rather
	// than stored.
	frag_data := Deferred_Lighting_Frag_Data{
		inverse_view_projection = linalg.matrix4_inverse(r.view_projection),
	}
	sdl.PushGPUFragmentUniformData(r.cmd, 0, &frag_data, size_of(frag_data))

	// No vertex buffer, no index buffer -- fullscreen.vert.hlsl builds its
	// own three vertices from SV_VertexID, the same shape draw_skybox
	// already uses for skybox.vert.hlsl.
	r.bound_quad = false
	sdl.DrawGPUPrimitives(r.pass, 3, 1, 0, 0)

	// Nothing this proc just bound is what draw_model_immediate's own cache
	// expects for a mesh draw -- the transparent/LINES flush that runs
	// right after this in the same pass (pipeline_deferred_end) must not
	// skip a bind believing this quad's own samplers are still current.
	bind_cache_reset()
}

/*
	64 bytes: the one matrix `deferred_lighting.frag.hlsl` needs that the
	shared `Scene` cbuffer (lighting_core.hlsli) does not already carry --
	see that shader's own top comment for why position reconstruction needs
	it and gbuffer.hlsli's own top comment for why position is not simply a
	fifth G-buffer target instead.
*/
Deferred_Lighting_Frag_Data :: struct #align(16) {
	inverse_view_projection: matrix[4, 4]f32,
}
