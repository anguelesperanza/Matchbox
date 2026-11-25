package matchbox

/*
	Render
	======
	The render queue, shared by every target. render_mesh, render_sprite and the shapes
	only record a Render_Item between camera_start and camera_end; each backend's
	camera_end sorts and draws them. Recording is the same everywhere, so it is written once.
*/

import "core:math/linalg"
import "core:slice"

Blend_Mode :: enum {
	NONE,
	ALPHA,
}

/*How a draw uses the depth buffer. camera_end picks it: OPAQUE and TRANSPARENT in a world pass,
DISABLED in a screen pass, where what is drawn last lands on top*/
Depth_Mode :: enum {
	OPAQUE, // tested and written
	TRANSPARENT, // tested, not written, so things behind still show through
	DISABLED,
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
	material:Material, // how a lit mesh takes a highlight; an unlit one ignores it
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

/*
	Records one draw. Shared by render_mesh, render_sprite and the shapes. `material` is a model part's; the
	default is what a part without one gets, so a lit mesh drawn with render_mesh shines like a default model part
	rather than not at all. Sprites and shapes aren't lit and leave it
*/
@(private)
queue_render :: proc(mesh:Mesh, model:matrix[4,4]f32, tint:[4]f32, blend:Blend_Mode, cull:Cull_Mode, texture:Texture, uv_rectangle:[4]f32, alpha_cutoff:f32, material:Material = mbi.model_settings.default_material) {
	ensure(mbi.camera_active == true, "Drawing must happen between camera_start and camera_end")

	item := Render_Item{mesh = mesh, model = model, tint = tint, cull = cull, texture = texture, uv_rectangle = uv_rectangle, alpha_cutoff = alpha_cutoff, material = material}

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

/*
	Puts the queue in the order camera_end draws it. Shared so every target draws the same
	scene the same way; only the key the opaque items are grouped by is the backend's
	(calculate_render_item_sort_key), because it is made of GPU objects.

	Opaque items are grouped by texture, then mesh, so the same objects are bound back to back.
	The sort is stable, so equal items keep the order they were submitted in. A screen pass
	skips it: with depth off, submission order is the paint order.
	Transparent items go farthest first, so nearer ones blend over farther ones
*/
@(private)
sort_render_queue :: proc() {
	if mbi.screen_pass == false {
		slice.stable_sort_by(mbi.opaque_items[:], proc(a, b:Render_Item) -> bool {
			key_a := calculate_render_item_sort_key(a)
			key_b := calculate_render_item_sort_key(b)
			if key_a[0] != key_b[0] do return key_a[0] < key_b[0]
			return key_a[1] < key_b[1]
		})
	}

	slice.stable_sort_by(mbi.transparent_items[:], proc(a, b:Render_Item) -> bool {
		return a.depth > b.depth
	})
}
