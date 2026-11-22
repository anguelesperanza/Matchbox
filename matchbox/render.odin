package matchbox

/*
	Render
	======
	The render queue, shared by every target. render_mesh, render_sprite and the shapes
	only record a Render_Item between camera_start and camera_end; each backend's
	camera_end sorts and draws them. Recording is the same everywhere, so it is written once.
*/

import "core:math/linalg"

Blend_Mode :: enum {
	NONE,
	ALPHA,
}

Cull_Mode :: enum {
	BACK, // Skips triangles not facing the camera
	NONE, // Draws all triangles of a sprite and two-sided quads
}

Render_Item :: struct {
	mesh:Mesh,
	model:matrix[4,4]f32,
	tint:[4]f32,
	cull:Cull_Mode,
	depth:f32,
	texture:Texture,
	uv_rectangle:[4]f32,
	alpha_cutoff:f32,
}

/*Queues a mesh to be drawn at camera_end. `model` places it in the world.
Use blend = .ALPHA for see-through things; Matchbox draws them after the opaque ones, farthest first*/
render_mesh :: proc(
	mesh:Mesh,
	model:matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
	tint:[4]f32 = {1, 1, 1, 1},
	blend:Blend_Mode = .NONE,
	cull:Cull_Mode = .BACK,
	texture:Texture = {},
) {
	queue_render(mesh, model, tint, blend, cull, texture, {0, 0, 1, 1}, 0)
}

/*Records one draw. Shared by render_mesh, render_sprite and the shapes*/
@(private)
queue_render :: proc(mesh:Mesh, model:matrix[4,4]f32, tint:[4]f32, blend:Blend_Mode, cull:Cull_Mode, texture:Texture, uv_rectangle:[4]f32, alpha_cutoff:f32) {
	ensure(mbi.camera_active == true, "Drawing must happen between camera_start and camera_end")

	item := Render_Item{mesh = mesh, model = model, tint = tint, cull = cull, texture = texture, uv_rectangle = uv_rectangle, alpha_cutoff = alpha_cutoff}

	switch blend {
	case .NONE:
		append(&mbi.opaque_items, item)

	case .ALPHA:
		// Where the model's origin is in view space. The camera looks down -Z,
		// so things in front of it have a negative z; flip it so bigger = farther
		view_position := mbi.view * model * [4]f32{0, 0, 0, 1}
		item.depth = -view_position.z
		append(&mbi.transparent_items, item)
	}
}
