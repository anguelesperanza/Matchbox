package matchbox

import sdl "vendor:sdl3"

/*
	Render pipeline -- clustered forward+
	----------------------------------------
	`Render_Pipeline_Kind.CLUSTERED`'s own half of the dispatch
	(`pipeline_begin_frame`/`pipeline_cluster_buffers`, render3d.odin).

	Everything this pipeline needs beyond plain forward is `light_cull.odin`'s
	own per-frame assignment -- no new render pass, no new pipeline object,
	no new vertex layout. `pipeline_begin_frame` calling into here once at the
	top of `begin_drawing_3d`, and `pipeline_cluster_buffers` calling in here
	once per draw, are the only two places this pipeline exists on the CPU
	side at all; the rest of the difference lives entirely in
	`shade_lights`'s own branch (lighting_core.hlsli).
*/

// Rebuilds and reuploads Lighting.cluster for the camera this frame's 3D
// pass just opened with -- see cluster_build_and_upload's own doc comment
// (light_cull.odin) for why this runs every frame rather than only when the
// light list changes.
@(private)
pipeline_clustered_begin :: proc(camera: Camera3D) {
	cluster_build_and_upload(camera)
}

/*
	`Lighting.cluster`'s own buffers, falling back to `Renderer`'s
	placeholders on the one frame `CLUSTERED` is selected before
	`pipeline_clustered_begin` has run for it yet (a game calling
	`draw_model` before `begin_drawing_3d` for the same frame does not exist
	in this package -- draw_model_immediate asserts a pass is open -- but a
	buffer that starts out nil the moment `set_lighting` first selects this
	pipeline is a real state to be in for the rest of that same call, so this
	stays defensive rather than assuming begin always ran first).
*/
@(private)
pipeline_clustered_cluster_buffers :: proc() -> (ranges, indices: ^sdl.GPUBuffer) {
	c := &mbi.renderer.lighting.cluster
	ranges  = c.ranges_buffer        if c.ranges_buffer        != nil else mbi.renderer.default_cluster_ranges_buffer
	indices = c.light_indices_buffer if c.light_indices_buffer != nil else mbi.renderer.default_cluster_light_indices_buffer
	return
}
