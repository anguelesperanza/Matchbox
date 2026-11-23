package matchbox

/*
	Model
	=====
	What one model file loads into, or one generator builds: several parts, each its own Mesh
	with its own texture and colour, because a glTF scene routinely has more than one of both.
	Shared by every target. A part is drawn through the same render queue as everything else
	(render.odin), so a model sorts, depth-tests and blends like a sprite does and needs no
	backend code of its own.

	Ported from main's model.odin and render3d.odin with the names brought to the house rules:
	draw_model -> render_model, model_center -> calculate_model_center, transform_matrix ->
	calculate_transform_matrix. Left out until their phases: lighting and normals (G2),
	skinning and the animator (G6), shadows, and the line models (wire cube, grid), which need
	a line topology no backend has yet.

	A Mesh holds 16-bit indices, because the 3DS and the Vita draw with them, so a part has at
	most 65536 vertices. The glTF loader splits nothing: a bigger primitive stops with a message
*/

import "core:math/linalg"

/*
	Where a model is, which way it is turned, and how big it is.

	**The zero value is not the identity.** A zeroed Transform has a scale of zero and a
	rotation that is not a rotation, and a model drawn with one is a model you cannot see.
	`create_transform()` with no arguments is the identity, and render_model's position form exists so the
	common case, a position and one scale, never has to build one at all.

	Rotation is a quaternion because that is what a physics library hands back, so a body's
	orientation reaches a draw call without being taken apart into angles and put back
*/
Transform :: struct {
	position:[3]f32,
	rotation:quaternion128,
	scale:[3]f32,
}

/*A Transform at `position`, turned by `rotation`, at one scale on every axis. No arguments is the identity*/
create_transform :: proc(position:[3]f32 = {}, rotation:quaternion128 = linalg.QUATERNIONF32_IDENTITY, scale:f32 = 1) -> Transform {
	return Transform{position = position, rotation = rotation, scale = {scale, scale, scale}}
}

/*Scale, then rotate, then move: the order that turns a model about its own origin rather than swinging it round the world's*/
calculate_transform_matrix :: proc(transform:Transform) -> matrix[4, 4]f32 {
	return calculate_model_matrix(transform.position, transform.rotation, transform.scale)
}

/*
	`transform` rewritten so that `pivot`, a point in the model's own space, lands on
	`transform.position`. Scale is applied before the pivot is cancelled, matching
	calculate_transform_matrix, so a model drawn at half size pivots about the same point on the
	mesh rather than one that has slid toward the origin
*/
calculate_transform_pivoted :: proc(transform:Transform, pivot:[3]f32) -> Transform {
	result := transform
	result.position -= linalg.quaternion_mul_vector3(transform.rotation, pivot * transform.scale)
	return result
}

/*One lump of geometry with one look. The texture is the model's (Model.textures); the part only names it*/
Model_Part :: struct {
	mesh:Mesh,
	texture:Texture, // zero for an untextured part, which draws in `color` alone
	color:[4]f32, // multiplied with the texture and the tint: a glTF material's base colour factor
	blend:Blend_Mode, // .ALPHA for a glTF material whose alpha mode is BLEND
	alpha_cutoff:f32, // a glTF MASK material's cutoff; 0 keeps every pixel
	cull:Cull_Mode, // .NONE for a double-sided glTF material
}

/*
	A whole model. `bounds_min` / `bounds_max` are its extents in its own space, measured once
	while the vertices were in hand: what a game sizes a collider from, and centres a camera on.
	`textures` are the ones the model owns and destroy_model frees, each once, however many
	parts use it
*/
Model :: struct {
	parts:[]Model_Part,
	textures:[]Texture,
	bounds_min:[3]f32,
	bounds_max:[3]f32,
}

/*The middle of the model's own bounds: what a physics library wants as a centre, and the usual pivot*/
calculate_model_center :: proc(model:Model) -> [3]f32 {
	return (model.bounds_min + model.bounds_max) * 0.5
}

/*How big the model is on each axis, in its own space before any Transform*/
calculate_model_size :: proc(model:Model) -> [3]f32 {
	return model.bounds_max - model.bounds_min
}

/*
	Draws a model, in whichever of the three ways the arguments ask for, as `render_text` does
	for what it is given:
		render_model(model, transform)              render_model_transform
		render_model(model, position, scale)        render_model_at
		render_model(model, pivot, transform)       render_model_pivoted
	Each also takes a `tint` last. The three can't be mistaken for each other: only
	render_model_transform takes a Transform second, and only render_model_pivoted takes one third
*/
render_model :: proc {
	render_model_transform,
	render_model_at,
	render_model_pivoted,
}

/*
	Queues every part of `model` to be drawn at camera_end. `tint` multiplies each part's own
	colour; a tint or a part colour with alpha below 1 draws that part blended. Part of the
	`render_model` group
*/
render_model_transform :: proc(model:Model, transform:Transform, tint:[4]f32 = {1, 1, 1, 1}) {
	model_matrix := calculate_transform_matrix(transform)
	for part in model.parts {
		color := part.color * tint
		blend := part.blend
		if color.a < 1 do blend = .ALPHA
		queue_render(part.mesh, model_matrix, color, blend, part.cull, part.texture, {0, 0, 1, 1}, part.alpha_cutoff)
	}
}

/*A model at a position, at one scale on every axis and unturned. What most draws want. Part of the `render_model` group*/
render_model_at :: proc(model:Model, position:[3]f32, scale:f32 = 1, tint:[4]f32 = {1, 1, 1, 1}) {
	render_model_transform(model, create_transform(position, scale = scale), tint)
}

/*
	A model placed and turned about `pivot`, a point in its own space, rather than about its
	origin; `transform.position` is where that point ends up. calculate_model_center(model) is
	the usual pivot.

	Why: render_model_transform places the origin, and a modelled character's origin is on the
	floor between its feet. Turned about that, it swings round its feet. A `pivot` field on
	Transform was the alternative and was rejected in main: it would be present and zero at
	nearly every construction site, and calculate_transform_matrix would quietly mean something
	new. Part of the `render_model` group
*/
render_model_pivoted :: proc(model:Model, pivot:[3]f32, transform:Transform, tint:[4]f32 = {1, 1, 1, 1}) {
	render_model_transform(model, calculate_transform_pivoted(transform, pivot), tint)
}

/*
	A model of one untextured white part, from geometry made in code. Bounds are measured off
	the vertices on the way past, since they are here now and will not be later. The slices
	can be freed afterwards
*/
create_model_from_mesh :: proc(vertices:[]Vertex, indices:[]u16) -> (model:Model) {
	model.parts = make([]Model_Part, 1)
	model.parts[0] = Model_Part{mesh = create_mesh(vertices, indices), color = {1, 1, 1, 1}}
	model.bounds_min, model.bounds_max = calculate_vertex_bounds(vertices)
	return
}

/*
	A model from CPU-side `data` (read_gltf_model on PC, read_model_file on the handhelds) and
	the textures already made from its images, one per image and in the same order; a zero
	Texture leaves the parts that name it untextured. The model takes the textures and frees them
	in destroy_model. Every target's load_model ends here, so a model is put together one way.

	Texture coordinates outside 0..1 do not repeat: textures are clamped on every target, and on
	the 3DS the image sits in a corner of a larger canvas, so a tiling texture shows its edge
	stretched instead
*/
create_model_from_data :: proc(data:Model_Data, textures:[]Texture) -> (model:Model) {
	model.textures = textures
	model.parts = make([]Model_Part, len(data.parts))
	for part, index in data.parts {
		model.parts[index] = Model_Part {
			mesh = create_mesh(part.vertices, part.indices),
			color = part.color,
			blend = part.blend,
			alpha_cutoff = part.alpha_cutoff,
			cull = part.cull,
		}
		if part.image >= 0 && part.image < len(textures) do model.parts[index].texture = textures[part.image]
	}
	model.bounds_min = data.bounds_min
	model.bounds_max = data.bounds_max
	return
}

/*Frees every part's geometry, then each texture the model owns, once*/
destroy_model :: proc(model:Model) {
	for part in model.parts do destroy_mesh(part.mesh)
	for texture in model.textures do destroy_texture(texture)
	delete(model.parts)
	delete(model.textures)
}

/*The smallest box holding every vertex. Zero for no vertices*/
@(private)
calculate_vertex_bounds :: proc(vertices:[]Vertex) -> (min_corner, max_corner:[3]f32) {
	if len(vertices) == 0 do return
	min_corner = vertices[0].position
	max_corner = vertices[0].position
	for vertex in vertices[1:] {
		min_corner = linalg.min(min_corner, vertex.position)
		max_corner = linalg.max(max_corner, vertex.position)
	}
	return
}

// ---- Generated models ----------------------------------------------------------------------
// The geometry is mesh.odin's (mesh_cube, mesh_plane, mesh_sphere, mesh_cylinder), where it can
// be tested without a GPU. White, so the tint is the colour

/*A cube `size` units on each side, centred on its own origin. Each face has its own vertices and the whole texture*/
create_cube_model :: proc(size:f32 = 1) -> Model {
	vertices, indices := mesh_cube(size, colored = false, allocator = context.temp_allocator)
	return create_model_from_mesh(vertices, indices)
}

/*A flat square of `size` units on the ground plane (x and z), facing up*/
create_plane_model :: proc(size:f32 = 1) -> Model {
	vertices, indices := mesh_plane(size, context.temp_allocator)
	return create_model_from_mesh(vertices, indices)
}

/*A sphere of `radius`, in rings of latitude and sectors of longitude*/
create_sphere_model :: proc(radius:f32 = 1, rings:int = 16, sectors:int = 24) -> Model {
	vertices, indices := mesh_sphere(radius, rings, sectors, context.temp_allocator)
	return create_model_from_mesh(vertices, indices)
}

/*A cylinder of `radius` and `height`, upright about Y and centred on its own origin*/
create_cylinder_model :: proc(radius:f32 = 0.5, height:f32 = 1, sectors:int = 24) -> Model {
	vertices, indices := mesh_cylinder(radius, height, sectors, context.temp_allocator)
	return create_model_from_mesh(vertices, indices)
}
