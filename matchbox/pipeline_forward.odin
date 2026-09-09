package matchbox

import sdl "vendor:sdl3"

/*
	Render pipeline -- forward
	----------------------------
	`Render_Pipeline_Kind.FORWARD`'s own half of the dispatch
	(`pipeline_begin_frame`/`pipeline_cluster_buffers`, render3d.odin).

	There was barely anything here through P6, and that was the point of
	splitting it out at all: forward has been every mesh draw in this package
	since before `Render_Pipeline_Kind` existed to name it, so its own module
	did nothing beyond standing in as `CLUSTERED`'s sibling in the one switch
	each dispatcher runs.

	**P7b gave it a real job: the depth prepass.** SSAO has to know how
	occluded a point is *before* that point is shaded (`ssao.odin`), and a
	forward pipeline shades during the geometry pass -- so the depth it
	produces arrives one pass too late to be useful. The fix is the standard
	one: draw the geometry once with a fragment shader that writes nothing,
	run the AO pass over the depth that leaves, then draw the scene for real.

	**Which costs an immediate-mode API something specific, and it is worth
	naming.** A prepass has to draw every model in the frame before the frame
	has said what its models are. So under this pipeline, with SSAO on,
	`draw_model` stops drawing and starts *queueing* -- `Renderer.scene_deferred`
	-- and `end_drawing_3d` replays the queue twice. That is not a new idea
	here: P6's deferred pipeline already queues the skybox and every
	transparent part for a replay into a later pass, and this uses the same
	`Pending_Shadow_Model` list shape and the same "replay with a flag set"
	trick. What is new is that the *whole* frame goes through it, which is why
	`draw_model_immediate` and `draw_skybox` both had to grow a branch ahead
	of their own "no pass is open" guards: with the scene deferred there
	genuinely is no pass yet, and a guard written to catch a stray draw would
	otherwise silently eat every model in the scene.

	`CLUSTERED` shares all of this, the same way it already shares forward's
	fragment path -- the prepass has no more to do with which lights a
	fragment loops over than it does with which BRDF shades it.
*/

// Nothing to build before the first draw -- FORWARD needs no per-frame state
// beyond what push_lighting (lighting.odin) already pushes for every
// pipeline, camera included.
@(private)
pipeline_forward_begin :: proc(camera: Camera3D) {
}

/*
	Whether this frame's scene draws have to be held back rather than drawn as
	they arrive -- see this file's own top comment.

	True only when a forward-family pipeline is running *and* something needs
	the scene's depth before the scene is shaded, which today means SSAO
	alone. `DEFERRED` is excluded because it has no such problem: its fill
	pass writes depth and its lighting pass runs afterward, so the AO pass
	slots between the two with nothing to defer.

	One procedure rather than the condition written out at each of the four
	places that ask it, because those four have to agree exactly. A
	`draw_model` that queues and an `end_drawing_3d` that never replays is an
	empty screen, and it is the kind of empty screen with no error attached to
	it.
*/
@(private)
pipeline_forward_defers_scene :: proc() -> bool {
	settings := mbi.renderer.lighting.settings
	return settings.pipeline != .DEFERRED && settings.ssao.enabled
}

/*
	Draws every held model into the scene's own depth buffer and nothing else,
	so that `ssao_run` has this frame's depth to work from before a single
	pixel has been shaded.

	Clears depth, since this is now the first thing that touches it; the scene
	pass that follows *loads* rather than clearing, which is the second thing
	this buys -- every fragment the scene pass then rasterizes already has its
	final depth to test against, so anything hidden is rejected before its
	fragment shader runs. On a scene with real overdraw that pays for a good
	part of the extra geometry pass. Nothing here can measure it.

	`pending_shadow_models` is replayed alongside the queue for the same
	reason it is replayed into the scene pass: a model marked `casts_shadow`
	is drawn by the framework rather than by the game, so it is in the frame
	and has to occlude like anything else in it. Missing it would leave a
	hole in the AO exactly where the most prominent objects in the scene are.
*/
@(private)
pipeline_forward_depth_prepass :: proc() -> bool {
	r := &mbi.renderer

	depth_texture := current_depth_texture()
	if depth_texture == nil do return false

	depth := sdl.GPUDepthStencilTargetInfo{
		texture     = depth_texture,
		clear_depth = 1,
		load_op     = .CLEAR,
		store_op    = .STORE, // the whole point: ssao_run reads it next
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, nil, 0, &depth)
	if r.pass == nil do return false

	bind_cache_reset()

	r.in_depth_prepass = true
	for pending in r.pending_scene_models {
		draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
	}
	for pending in r.pending_shadow_models {
		draw_model_immediate(pending.model, pending.transform, pending.tint, pending.animator)
	}
	r.in_depth_prepass = false

	sdl.EndGPURenderPass(r.pass)
	r.pass = nil

	return true
}

/*
	The two cluster-only storage buffers, standing in with `Renderer`'s own
	1-element placeholders -- see that struct's own doc comment on
	`default_cluster_ranges_buffer`/`default_cluster_light_indices_buffer`
	for why they have to be bound to *something* even though `shade_lights`
	(lighting_core.hlsli) never reads either of them under `FORWARD`.
*/
@(private)
pipeline_forward_cluster_buffers :: proc() -> (ranges, indices: ^sdl.GPUBuffer) {
	return mbi.renderer.default_cluster_ranges_buffer, mbi.renderer.default_cluster_light_indices_buffer
}
