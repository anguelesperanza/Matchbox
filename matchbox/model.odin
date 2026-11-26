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
	calculate_transform_matrix. Skinning and the animator are here since G6 (skeleton.odin, animator.odin,
	render_model_animated). Left out until their phases: shadows, and the line models (wire cube, grid), which need a line topology no backend has
	yet.

	Every part is a lit mesh (Lit_Vertex, create_lit_mesh) with a Material, loaded or generated
	alike (G2 L4-2), so a model lights whenever the scene does (set_lighting) and draws as it
	always did when it doesn't.

	A Mesh holds 16-bit indices, because the 3DS and the Vita draw with them, so a part has at
	most 65536 vertices. The glTF loader splits nothing: a bigger primitive stops with a message
*/

import "core:math/linalg"

/*
	Where a model is, which way it is turned, and how big it is.

	**The zero value is not the identity.** A zeroed Transform has a scale of zero and a
	rotation that is not a rotation, and a model drawn with one is a model you cannot see.
	`create_transform()` with no arguments is the identity, and render_model's position form exists so the
	common case, a model placed and nothing else, never has to build one at all.

	The same fact is why an untyped `{x, y, z}` must never reach a Transform parameter: Odin fills
	the fields in order, position x on every axis, rotation y, scale z, and the model is drawn at
	zero size (see render_model)

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

/*
	How a part takes the light. Per part rather than per light, so two models under one sun can
	shine differently, as a varnished crate and a cloth sack do. Diffuse needs no setting: it is
	the part's colour and texture.

	`lighting` chooses per pixel or per vertex for this part; nil follows the scene's
	(Lighting_Settings.mode). On the material, as engines that offer both put it (Godot's shading
	mode is a material's), rather than on the light or the model: it is about the surface, how
	smooth its shading must look against what it costs. Not stored in an .mbm: a file's materials
	describe the surface, and how a game spends its vertex and pixel time is the game's call
*/
Material :: struct {
	shininess:f32, // the highlight's power: higher is smaller and sharper
	specular_strength:f32, // 0 for no highlight, 1 for the light's whole specular colour
	lighting:Maybe(Lighting_Mode),
}

/*Fixed values the engine uses for models, held in mbi.model_settings*/
Model_Settings :: struct {
	default_material:Material, // a part with no material of its own: a glTF primitive without one, and the generated models
	max_shininess:f32, // the sharpest highlight a glTF roughness turns into; a roughness of 0 would otherwise be infinite
}

/*One lump of geometry with one look. The texture is the model's (Model.textures); the part only names it*/
Model_Part :: struct {
	mesh:Mesh, // a lit mesh (create_lit_mesh)
	material:Material,
	texture:Texture, // zero for an untextured part, which draws in `color` alone
	color:[4]f32, // multiplied with the texture and the tint: a glTF material's base colour factor
	blend:Blend_Mode, // .ALPHA for a glTF material whose alpha mode is BLEND
	alpha_cutoff:f32, // a glTF MASK material's cutoff; 0 keeps every pixel
	cull:Cull_Mode, // .NONE for a double-sided glTF material

	// A skinned part only (mesh.skinned): the zero values mean nothing, so read these only when it is
	skin:int, // which of the skeleton's skins deforms it
	mesh_node:int, // the node its mesh hangs off, whose own transform glTF says a skinned mesh ignores (-1 for none)
	joint_map:[]u32, // the skin's joints this part's vertices use, in the order their `joints` name them. At most mbi.skin_settings.joint_limit
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
	skeleton:Skeleton, // empty for a model with none: a crate (skeleton.odin)
	animations:[]Model_Animation,
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
		render_model(model, position)               render_model_at
		render_model(model, pivot, transform)       render_model_pivoted
	Each also takes a `tint` last. A scale goes in a Transform: create_transform(position, scale = 2).

	A position written straight into the call has to be typed, `[3]f32{-3, 0, 0}`, or held in a
	variable. An untyped `{-3, 0, 0}` fits a Transform too, read field by field as a zero-sized one.
	render_model_at deliberately leaves as many defaults unfilled as render_model_transform, so
	Odin calls that ambiguous and stops the build. With a `scale` parameter it did not: Odin picked
	the overload with fewer defaults left over, the Transform, and the model vanished silently on
	every target (found 2026-11-25, docs/3ds_fragment_lighting_plan.md). Don't add a defaulted
	parameter to render_model_at without checking that the bare literal still fails to compile
*/
render_model :: proc {
	render_model_transform,
	render_model_at,
	render_model_pivoted,
	render_model_animated,
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
		queue_render(part.mesh, model_matrix, color, blend, part.cull, part.texture, {0, 0, 1, 1}, part.alpha_cutoff, part.material)
	}
}

/*
	A skinned model posed by `animator`, which update_animator has worked the pose out for. The palettes are
	copied into the frame's joint arena here, because a draw is only recorded now and happens at camera_end,
	by when the animator may have been updated again or a second character drawn from the same model. A
	skinned part drawn with render_model(model, transform) instead shows its bind pose (a T-pose). Part of the
	`render_model` group
*/
render_model_animated :: proc(model:Model, animator:Animator, transform:Transform, tint:[4]f32 = {1, 1, 1, 1}) {
	model_matrix := calculate_transform_matrix(transform)
	for part, index in model.parts {
		color := part.color * tint
		blend := part.blend
		if color.a < 1 do blend = .ALPHA

		joint_offset, joint_count := 0, 0
		if part.mesh.skinned && index < len(animator.pose.palettes) {
			joint_offset, joint_count = push_skin_palette(animator.pose.palettes[index])
		}
		queue_render(part.mesh, model_matrix, color, blend, part.cull, part.texture, {0, 0, 1, 1}, part.alpha_cutoff, part.material, joint_offset, joint_count)
	}
}

/*A model at a position, at its own size and unturned. What most draws want. Part of the `render_model` group*/
render_model_at :: proc(model:Model, position:[3]f32, tint:[4]f32 = {1, 1, 1, 1}) {
	render_model_transform(model, create_transform(position), tint)
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
	A model of one untextured white part, from geometry made in code, with the default
	material. Bounds are measured off the vertices on the way past, since they are here now and
	will not be later. The slices can be freed afterwards
*/
create_model_from_mesh :: proc(vertices:[]Lit_Vertex, indices:[]u16) -> (model:Model) {
	model.parts = make([]Model_Part, 1)
	model.parts[0] = Model_Part {
		mesh = create_lit_mesh(vertices, indices),
		material = mbi.model_settings.default_material,
		color = {1, 1, 1, 1},
	}
	model.bounds_min, model.bounds_max = calculate_vertex_bounds(vertices)
	return
}

/*
	A model from CPU-side `data` (read_gltf_model on PC, read_model_file on the handhelds) and
	the textures already made from its images, one per image and in the same order; a zero
	Texture leaves the parts that name it untextured. The model takes the textures and frees them
	in destroy_model. Every target's load_model ends here, so a model is put together one way.

	The model also takes the skeleton, the clips and each skinned part's joint map: moved, not copied, so
	they are the model's and `data` must then be freed with destroy_model_data_leftovers, which leaves them

	Texture coordinates outside 0..1 do not repeat: textures are clamped on every target, and on
	the 3DS the image sits in a corner of a larger canvas, so a tiling texture shows its edge
	stretched instead
*/
create_model_from_data :: proc(data:Model_Data, textures:[]Texture) -> (model:Model) {
	model.textures = textures
	model.parts = make([]Model_Part, len(data.parts))
	for part, index in data.parts {
		model.parts[index] = Model_Part {
			material = part.material,
			color = part.color,
			blend = part.blend,
			alpha_cutoff = part.alpha_cutoff,
			cull = part.cull,
		}
		if len(part.skinned_vertices) > 0 {
			model.parts[index].mesh = create_skinned_mesh(part.skinned_vertices, part.indices)
			model.parts[index].skin = part.skin
			model.parts[index].mesh_node = part.mesh_node
			model.parts[index].joint_map = part.joint_map
		} else {
			model.parts[index].mesh = create_lit_mesh(part.vertices, part.indices)
		}
		if part.image >= 0 && part.image < len(textures) do model.parts[index].texture = textures[part.image]
	}
	model.bounds_min = data.bounds_min
	model.bounds_max = data.bounds_max
	model.skeleton = data.skeleton
	model.animations = data.animations
	return
}

/*Frees every part's geometry, then each texture the model owns, once*/
destroy_model :: proc(model:Model) {
	for part in model.parts {
		destroy_mesh(part.mesh)
		delete(part.joint_map)
	}
	for texture in model.textures do destroy_texture(texture)
	destroy_skeleton(model.skeleton)
	destroy_model_animations(model.animations)
	delete(model.parts)
	delete(model.textures)
}

/*
	A glTF material's roughness and metallic factors as the Blinn-Phong highlight Matchbox
	draws. glTF describes a physically based surface that no target here shades, so this is an
	approximation, chosen so the common cases read right rather than to match a PBR renderer:

	- shininess = 2 / roughness^4 - 2, the usual Blinn-Phong power for a microfacet roughness
	  (alpha = roughness^2): 0.5 gives 30, 0.3 gives 245 (kept to max_shininess), 1 gives 0
	  (kept to 1, a highlight spread over the whole lit side)
	- strength = (1 - roughness) * (1 + metallic), kept to 0..1: a fully rough surface has no
	  highlight, and a metal's is twice a plastic's. Blender's default material (roughness 0.5,
	  metallic 0) comes out at 0.5, the strength of the default material. A physically based
	  dielectric reflects only 4% head-on, but at that a plastic would show no highlight at all
	  in a Blinn-Phong scene
*/
calculate_material_from_roughness :: proc(roughness, metallic:f32) -> Material {
	roughness := clamp(roughness, 0, 1)
	metallic := clamp(metallic, 0, 1)
	power := roughness * roughness * roughness * roughness
	shininess := mbi.model_settings.max_shininess
	if power > 0 do shininess = clamp(2 / power - 2, 1, mbi.model_settings.max_shininess)
	return Material{shininess = shininess, specular_strength = clamp((1 - roughness) * (1 + metallic), 0, 1)}
}

/*The smallest box holding every vertex. Zero for no vertices*/
@(private)
calculate_vertex_bounds :: proc(vertices:[]Lit_Vertex) -> (min_corner, max_corner:[3]f32) {
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
