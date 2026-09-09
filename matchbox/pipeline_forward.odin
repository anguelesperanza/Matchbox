package matchbox

import sdl "vendor:sdl3"

/*
	Render pipeline -- forward
	----------------------------
	`Render_Pipeline_Kind.FORWARD`'s own half of the dispatch
	(`pipeline_begin_frame`/`pipeline_cluster_buffers`, render3d.odin).

	There is barely anything here, and that is the point of splitting it out
	at all: forward has been every mesh draw in this package since before
	`Render_Pipeline_Kind` existed to name it, so its own module does nothing
	beyond standing in as `CLUSTERED`'s sibling in the one switch each
	dispatcher runs -- see `pipeline_clustered.odin` for the pipeline that
	actually needs its own per-frame work.
*/

// Nothing to build before the first draw -- FORWARD needs no per-frame state
// beyond what push_lighting (lighting.odin) already pushes for every
// pipeline, camera included.
@(private)
pipeline_forward_begin :: proc(camera: Camera3D) {
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
