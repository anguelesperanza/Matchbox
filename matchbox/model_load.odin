
package matchbox

/*
	Model -- loading
	----------------
	Reading a `.gltf` or `.glb` off disk and putting it on the GPU.

	The parsing is `matchbox/gltf2`'s, which is a vendored package and not
	something to reimplement: it reads the JSON, unpacks the GLB chunks, and
	decodes the base64 `data:` URIs that a self-contained export keeps its
	buffers and textures in. What is here is everything after that -- pulling
	vertices out of accessors, flattening the node hierarchy, and handing the
	results to the GPU.

	**Why the accessors are read here rather than with `gltf2.buffer_slice`.**
	That helper asserts when a buffer view declares a `byteStride`, and every
	file this was written against declares one -- Blockbench writes a stride of
	12 on a tightly packed vec3 buffer, which is redundant but perfectly legal.
	So the helper cannot read the models it would be used for. Reading the bytes
	directly is forty lines, handles interleaved data as a side effect, and
	leaves the vendored package untouched.

	**What is read, and what is ignored.** Positions, normals, texture
	coordinates, indices, skins and animations, and a material's base colour,
	metallic-roughness, occlusion and emissive channels -- both the factors and
	the textures. Not cameras or morph targets, and not a tangent-space normal
	map: there is nowhere to apply one without a tangent basis this package
	does not have -- see `read_material`'s own doc comment and
	`lighting_rework.md` section 7.5. A file may contain any of these; they are
	skipped rather than failed on.
*/

import "core:encoding/json"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"

import sdl "vendor:sdl3"
import stbi "vendor:stb/image"

import gltf "./gltf2"


// -----------------------------------------------------------------------
// Loading
// -----------------------------------------------------------------------

/*
	Loads a model from a `.gltf` or `.glb` file.

	Through `read_entire_file`, so a model shipped inside an Android apk is
	reachable -- `gltf2.load_from_file` would reach for `core:os` and find
	nothing there.

	The scene's node hierarchy is flattened: every node's transform is
	accumulated down the tree and baked into the vertices, so the Model that
	comes back is in the file's own space and needs no further arrangement.
	Without that a model built out of parts -- a stove with its doors as
	separate nodes -- arrives as a heap at the origin.

	Returns a `File_Error` when the path could not be read and
	`Model_Error.Parse_Failed` when it could but the contents are not glTF. A
	missing model is a shipping mistake rather than a crash, and telling the two
	apart is the difference between "you forgot to copy the file" and "the
	export is wrong".

	**`shading` forces one shading model onto every part of the file.** Left
	nil -- the default -- each part gets whatever its own glTF material
	declares, which is `PBR_METALLIC` for essentially every real file and
	`UNLIT` for one carrying `KHR_materials_unlit`; see `read_material` for
	why honouring the file is the right default rather than an imposition.
	Passing a value is the one-line escape hatch for a game that wants
	something else across the board:

		model := mb.load_model("prop.glb", shading = .TOON)

	Per-part control needs no parameter at all -- a `Model`'s parts are
	writable, so `model.parts[i].material.shading = .TOON` already worked and
	still does. This exists because "shade this whole file the old way" is a
	common enough wish to deserve better than a loop at every call site.
*/
load_model :: proc(path: string, shading: Maybe(Shading_Model) = nil) -> (model: Model, err: Error) {
	bytes := read_entire_file(path, context.allocator) or_return
	defer delete(bytes)

	// GLB copies its binary chunks out of `bytes` during parse, so freeing them
	// above is safe for both forms.
	//
	// A `.vrm` is a GLB with extra JSON under `extensions` -- both VRM 0.0 and
	// 1.0 mandate the binary container, never the JSON-plus-separate-buffers
	// form. That is a spec promise, not a sniff, so the extension alone is
	// enough to know how to unpack it; `model_from_gltf` is what notices the
	// extra JSON and treats the model as a VRM one.
	ext := filepath.ext(path)
	is_glb := strings.equal_fold(ext, ".glb") || strings.equal_fold(ext, ".vrm")

	// Only used for a model that keeps its buffers or textures in files beside
	// it, which none of the assets this was built for do -- they embed
	// everything.
	//
	// Borrowed, not owned: `filepath.dir` hands back a slice of the string it
	// was given rather than a new one, so deleting it frees a pointer into the
	// middle of somebody else's allocation. Doing that crashes with heap
	// corruption several function calls later, in a place with nothing to do
	// with paths.
	dir := filepath.dir(path)

	data, parse_err := gltf.parse(bytes, {is_glb = is_glb, gltf_dir = dir})
	if parse_err != nil {
		log.errorf("could not parse model %s: %v", path, parse_err)
		return {}, Model_Error.Parse_Failed
	}
	defer gltf.unload(data)

	model = model_from_gltf(data)

	/*
		Applied to the finished model rather than threaded down through
		`model_from_gltf` and every part builder to `read_material`. The
		parameter would have to travel four procedures deep to reach the one
		place that sets `shading`, and every one of them would carry an
		argument it does not itself use -- where overwriting one field on each
		finished part says the same thing in three lines, at the one level
		that actually knows the caller asked.
	*/
	if forced, ok := shading.?; ok {
		for &part in model.parts {
			part.material.shading = forced
		}
	}

	return model, nil
}

// Everything after the parse: walk the scene, build the parts, measure the
// bounds.
@(private)
model_from_gltf :: proc(data: ^gltf.Data) -> Model {
	parts := make([dynamic]Model_Part)

	// Textures are shared between parts -- the stove's nine meshes use two
	// between them -- so each glTF texture is uploaded once and handed out.
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture, context.temp_allocator)
	defer delete(uploaded)

	low  := [3]f32{ max(f32),  max(f32),  max(f32)}
	high := [3]f32{-max(f32), -max(f32), -max(f32)}

	// NONE for every file that is not a VRM, at the cost of one map lookup on
	// `data.extensions` -- see `vrm.odin`. Everything downstream of this reads
	// as "do nothing" for that case, which is what makes VRM support free for
	// a game that never opens one.
	version    := vrm_version(data.extensions)
	correction := vrm_facing_correction(version)

	/*
		The same turn, seeded two different ways for two different kinds of
		node -- see `vrm.md`'s step 1 for why both are needed and what a file
		with only one of them fixed looks like.

		A skinned mesh's vertices never read this matrix at all (glTF says a
		skinned mesh ignores its node's transform, and `gather_mesh` already
		takes the skinned path around it); what turns a skinned VRM character
		is `build_skeleton`'s `root_correction` below. This one only reaches a
		static, unskinned node -- an accessory with no armature -- which has no
		other path to inherit the correction through.
	*/
	root_matrix := transform_matrix(Transform{rotation = correction, scale = {1, 1, 1}})

	// The default scene, or the first one, or -- for a file with no scene at
	// all, which is legal -- every mesh at the origin.
	scene_index := data.scene.? or_else 0

	if len(data.scenes) > 0 && int(scene_index) < len(data.scenes) {
		for root in data.scenes[scene_index].nodes {
			gather_node(data, root, root_matrix, &parts, &uploaded, &low, &high)
		}
	} else {
		for _, mesh_index in data.meshes {
			gather_mesh(data, gltf.Integer(mesh_index), root_matrix, &parts, &uploaded, &low, &high, 0, nil)
		}
	}

	if len(parts) == 0 {
		log.error("model has no drawable primitives")
		return {}
	}

	// Every skinned part gets a slice of one shared joint buffer, laid out
	// here as a running sum over the parts in order -- see `joint_offset`'s
	// doc comment on Model_Part. An unskinned part (skin < 0) keeps offset 0
	// and contributes nothing to the total; nothing ever reads its offset.
	total_joints: u32 = 0
	for &part in parts {
		if part.skin < 0 do continue
		part.joint_offset = total_joints
		total_joints += u32(len(part.joint_map))
	}

	return Model{
		parts        = parts[:],
		bounds_min   = low,
		bounds_max   = high,
		skeleton     = build_skeleton(data, correction),
		animations   = build_animations(data),
		total_joints = int(total_joints),
		vrm_humanoid = parse_vrm_humanoid(data.extensions, version),
	}
}

/*
	Walks one node and everything under it.

	`parent` is the transform accumulated so far. glTF nodes carry either a
	matrix or a translation/rotation/scale triple, never both -- and the parser
	defaults the one that is absent to the identity, so multiplying them
	together is right either way and needs no test for which form was used.
*/
@(private)
gather_node :: proc(
	data:     ^gltf.Data,
	index:    gltf.Integer,
	parent:   matrix[4, 4]f32,
	parts:    ^[dynamic]Model_Part,
	uploaded: ^map[gltf.Integer]^sdl.GPUTexture,
	low, high: ^[3]f32,
) {
	if int(index) >= len(data.nodes) do return
	node := data.nodes[index]

	world := parent * node.mat * transform_matrix(Transform{
		position = node.translation,
		rotation = node.rotation,
		scale    = node.scale,
	})

	if mesh, has_mesh := node.mesh.?; has_mesh {
		gather_mesh(data, mesh, world, parts, uploaded, low, high, index, node.skin)
	}

	for child in node.children {
		gather_node(data, child, world, parts, uploaded, low, high)
	}
}

// One mesh's primitives, each becoming a part.
@(private)
gather_mesh :: proc(
	data:     ^gltf.Data,
	index:    gltf.Integer,
	world:    matrix[4, 4]f32,
	parts:    ^[dynamic]Model_Part,
	uploaded: ^map[gltf.Integer]^sdl.GPUTexture,
	low, high: ^[3]f32,
	node:     gltf.Integer,
	skin:     Maybe(gltf.Integer),
) {
	if int(index) >= len(data.meshes) do return

	// Normals are directions, not places: they must not pick up the
	// translation, and under an uneven scale they shear unless the inverse
	// transpose is used. Worked out once per mesh rather than per vertex.
	normal_matrix := linalg.matrix4_inverse_transpose_f32(world)

	for primitive in data.meshes[index].primitives {
		// Triangles only. A file may hold line or point primitives and they are
		// skipped rather than drawn wrongly.
		if primitive.mode != .Triangles do continue

		/*
			A skinned primitive takes the other path entirely. Its vertices
			belong to the skin's space and the joint matrices are what put them
			anywhere, so baking this node's transform into them -- which is what
			`primitive_part` exists to do -- would apply the arrangement twice.

			glTF says as much: the transform of a node with a skinned mesh is
			not applied to the mesh. `animator_resolve` divides it back out.
		*/
		skin_index, has_skin := skin.?
		if has_skin && "JOINTS_0" in primitive.attributes {
			part, vertices, made := skinned_primitive_part(
				data, primitive, int(skin_index), u32(node), uploaded)
			if !made do continue

			for v in vertices {
				low^  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
				high^ = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
			}

			append(parts, part)
			continue
		}

		part, vertices, made := primitive_part(data, primitive, world, normal_matrix, uploaded)
		if !made do continue

		for v in vertices {
			low^  = {min(low.x,  v.pos.x), min(low.y,  v.pos.y), min(low.z,  v.pos.z)}
			high^ = {max(high.x, v.pos.x), max(high.y, v.pos.y), max(high.z, v.pos.z)}
		}

		append(parts, part)
	}
}

/*
	One primitive: vertices baked into model space, indices, and a material.

	The returned vertex slice is temp-allocated and only good for measuring the
	bounds -- the copy that matters is already on the GPU by then.
*/
@(private)
primitive_part :: proc(
	data:          ^gltf.Data,
	primitive:     gltf.Mesh_Primitive,
	world:         matrix[4, 4]f32,
	normal_matrix: matrix[4, 4]f32,
	uploaded:      ^map[gltf.Integer]^sdl.GPUTexture,
) -> (part: Model_Part, vertices: []Vertex3D, ok: bool) {
	position_accessor, has_position := primitive.attributes["POSITION"]
	if !has_position {
		log.error("primitive has no POSITION, skipped")
		return {}, nil, false
	}

	positions := read_vec3(data, position_accessor) or_return
	count     := len(positions)

	normals := read_vec3_optional(data, primitive.attributes, "NORMAL", count)
	uvs     := read_vec2_optional(data, primitive.attributes, "TEXCOORD_0", count)

	vertices = make([]Vertex3D, count, context.temp_allocator)
	for i in 0 ..< count {
		// Baked here rather than at draw time. A node transform is a property
		// of the file's arrangement, not of where the game later puts the
		// model, so folding it in now means a part is one buffer and one draw.
		p := world * [4]f32{positions[i].x, positions[i].y, positions[i].z, 1}
		n := normal_matrix * [4]f32{normals[i].x, normals[i].y, normals[i].z, 0}

		vertices[i] = Vertex3D{
			pos    = p.xyz,
			normal = linalg.normalize0(n.xyz),
			uv     = uvs[i],
		}
	}

	indices := read_indices(data, primitive, count)

	err: Error
	part, err = upload_mesh(vertices, indices)
	if err != nil {
		log.errorf("could not upload a mesh primitive: %v", err)
		return {}, nil, false
	}

	// upload_mesh already set part.material to MATERIAL_DEFAULTS; read_material
	// replaces it wholesale rather than filling in one field at a time, since
	// a primitive with no material is exactly the MATERIAL_DEFAULTS case again.
	part.material = read_material(data, primitive.material, uploaded)

	return part, vertices, true
}

/*
	One skinned primitive: the same three attributes, plus the joints and
	weights, and no node transform baked in.

	The bounds measured off these are the bind pose -- the shape the character
	was modelled in, arms out. That is the right answer for the thing bounds are
	for here, which is standing a model on the ground: a walk cycle moves the
	feet a few centimetres and a bounding box that breathed with the animation
	would make the model bob.
*/
@(private)
skinned_primitive_part :: proc(
	data:      ^gltf.Data,
	primitive: gltf.Mesh_Primitive,
	skin:      int,
	node:      u32,
	uploaded:  ^map[gltf.Integer]^sdl.GPUTexture,
) -> (part: Model_Part, vertices: []Vertex3D_Skinned, ok: bool) {
	position_accessor, has_position := primitive.attributes["POSITION"]
	if !has_position {
		log.error("skinned primitive has no POSITION, skipped")
		return {}, nil, false
	}

	positions := read_vec3(data, position_accessor) or_return
	count     := len(positions)

	normals := read_vec3_optional(data, primitive.attributes, "NORMAL", count)
	uvs     := read_vec2_optional(data, primitive.attributes, "TEXCOORD_0", count)
	joints  := read_joints(data, primitive.attributes, count)
	weights := read_weights(data, primitive.attributes, count)

	/*
		A compact palette for this part alone.

		A vertex's joint index names a slot in the *skin*, and a rig's skin
		routinely has more joints than any one primitive touches: the character
		this was found on has 66 joints in its skin and no primitive using more
		than 37 of them. So each part gets a palette holding only the joints it
		uses, and its vertices are rewritten to index that -- `joint_map` carries
		a compact slot back to the skin's joint so `animator_resolve` can fill
		it. Unbounded: the palette is a storage buffer now (see `joint_offset`
		on `Model_Part`), so there is no longer a limit on how many distinct
		joints one primitive may name.
	*/
	skin_joints := 0
	if skin >= 0 && skin < len(data.skins) do skin_joints = len(data.skins[skin].joints)

	compact := make(map[u32]u32, context.temp_allocator)
	defer delete(compact)

	order := make([dynamic]u32, 0, min(skin_joints, 64))

	out_of_range := 0

	vertices = make([]Vertex3D_Skinned, count, context.temp_allocator)
	for i in 0 ..< count {
		joint  := joints[i]
		weight := weights[i]

		dropped := false
		for k in 0 ..< 4 {
			/*
				A zero-weight slot is still indexed by the shader and then
				multiplied by nothing, so it only has to be *valid*. Slot 0
				always exists, and pointing it there keeps every index inside
				the palette without inventing an influence.
			*/
			if weight[k] <= 0 {
				joint[k] = 0
				continue
			}

			if int(joint[k]) >= skin_joints {
				joint[k]  = 0
				weight[k] = 0
				dropped   = true
				out_of_range += 1
				continue
			}

			slot, known := compact[joint[k]]
			if !known {
				slot = u32(len(order))
				compact[joint[k]] = slot
				append(&order, joint[k])
			}
			joint[k] = slot
		}

		// Dropping a weight leaves the four summing short, and the shader uses
		// that sum unscaled -- see read_weights.
		if dropped {
			sum := weight[0] + weight[1] + weight[2] + weight[3]
			if sum > 0 {
				weight = {weight[0] / sum, weight[1] / sum, weight[2] / sum, weight[3] / sum}
			} else {
				joint  = {0, 0, 0, 0}
				weight = {1, 0, 0, 0}
			}
		}

		vertices[i] = Vertex3D_Skinned{
			pos     = positions[i],
			normal  = normals[i],
			uv      = uvs[i],
			joints  = joint,
			weights = weight,
		}

	}

	// At least one slot, so a part whose influences were all dropped still has
	// the identity entry its vertices now point at.
	if len(order) == 0 do append(&order, u32(0))

	if out_of_range > 0 {
		log.errorf("skinned primitive names %v joint indices past the skin's %v joints; those influences were dropped",
			out_of_range, skin_joints)
	}

	indices := read_indices(data, primitive, count)

	err: Error
	part, err = upload_skinned_mesh(vertices, indices, skin, node)
	if err != nil {
		delete(order)
		log.errorf("could not upload a skinned mesh primitive: %v", err)
		return {}, nil, false
	}
	part.joint_map = order[:]

	part.material = read_material(data, primitive.material, uploaded)

	return part, vertices, true
}

// -----------------------------------------------------------------------
// Materials
// -----------------------------------------------------------------------

/*
	A primitive's material, read in full: base colour, metallic-roughness and
	emissive (each a factor and a texture), and occlusion (a texture, glTF
	gives it no factor Matchbox's own Material has anywhere to put -- see
	this proc's own note on `occlusion_texture.strength` below). A primitive
	with no material, or a material index the file's own list does not reach,
	comes back `MATERIAL_DEFAULTS` unchanged -- lit, white, Blinn-Phong, the
	same as an untextured generated shape.

	**Deliberately leaves `shading` at `MATERIAL_DEFAULTS`' own Blinn-Phong**
	rather than switching a metallic-roughness-textured material to
	`Shading_Model.PBR_METALLIC`. `lighting_plan.md`'s own opening principle
	is that the *game* picks a shading model, not Matchbox -- a loader that
	silently chose one because a file happened to carry metallic-roughness
	data would be making that choice on the game's behalf, the exact thing
	the spec asks not to happen. A game that wants these parts PBR-shaded
	sets `.shading = .PBR_METALLIC` on the loaded parts itself, and after
	this proc that is the only thing left to set: the factors and textures
	read here are what makes that flip actually change the picture rather
	than reading zeroed fields the way it would have before this job.

	**Not read: `occlusion_texture.strength`.** glTF gives occlusion a
	blend-with-1.0 factor the same shape `metallic_factor`/`roughness_factor`
	are, but `Material`/`Surface` have no field for it -- occlusion is read
	as a plain texture sample (`Surface.occlusion`) with no material-level
	scalar next to it. Every asset this loader was built for leaves it at the
	spec default of 1 (full strength) anyway, so the gap is unread rather than
	silently wrong; a caller whose file sets it to something else does not get
	an error, just the texture at full strength.

	**Not read at all: `normal_texture`.** No tangent basis exists to apply
	one against -- see this file's own top comment and
	`lighting_rework.md` section 7.5.
*/
@(private)
read_material :: proc(
	data:     ^gltf.Data,
	material: Maybe(gltf.Integer),
	uploaded: ^map[gltf.Integer]^sdl.GPUTexture,
) -> Material {
	material_index, has_material := material.?
	if !has_material || int(material_index) >= len(data.materials) {
		return MATERIAL_DEFAULTS
	}

	gltf_material := data.materials[material_index]

	result := MATERIAL_DEFAULTS

	/*
		**The file's own declaration of what it is, not Matchbox's guess.**
		A glTF material carrying a `pbrMetallicRoughness` block -- which is
		every material that does not say otherwise, since the spec makes that
		the default parameterization -- is stating that it is a
		metallic-roughness surface. Loading it as Blinn-Phong would not be
		declining to choose on the game's behalf, which is what
		`lighting_plan.md`'s "the consumer selects" principle asks for; it
		would be choosing Blinn-Phong *for* the game while discarding what the
		file said, and leaving `metallic`, `roughness`, `occlusion` and
		`emissive` populated below for a model that reads none of them. A game
		that wants something else still overrides, per part or per file -- see
		`load_model`'s own `shading` parameter.

		`KHR_materials_unlit` is the one extension read here, and only for its
		presence: it is a rendering hint with no parameters of its own, so a
		key lookup is the whole of it.

		**`KHR_materials_pbrSpecularGlossiness` is deliberately not detected**,
		even though `Shading_Model.PBR_SPECGLOSS` exists and reads exactly the
		parameters it carries. The extension is archived, its factors live in
		an untyped `json.Value` this package has no typed parse for, and glTF
		requires a file using it to *also* supply a `pbrMetallicRoughness`
		block precisely so a client without the extension has something
		correct to fall back to. Matchbox is that client, and taking the
		documented fallback is the spec's own designed path rather than a gap
		-- reading the extension badly would be worse than reading the
		fallback well. A game with a spec-gloss asset it wants shaded that way
		sets `PBR_SPECGLOSS` itself and fills the factors it knows.
	*/
	result.shading = .PBR_METALLIC
	if extensions, ok := gltf_material.extensions.(json.Object); ok {
		if _, unlit := extensions["KHR_materials_unlit"]; unlit {
			result.shading = .UNLIT
		}
	}

	result.emissive = {
		f32(gltf_material.emissive_factor.x),
		f32(gltf_material.emissive_factor.y),
		f32(gltf_material.emissive_factor.z),
	}

	/*
		glTF's own defaults when `pbrMetallicRoughness` is present but a
		factor inside it is not are base colour white, metallic 1, roughness
		1 -- not Matchbox's own `create_material_pbr_metallic` defaults
		(metallic 0, roughness 0.5), which are a hand-authoring choice and not
		a reading of the spec. `gltf2.pbr_metallic_roughness_parse` already
		applies that 1/1 default *inside* a present block; what it cannot do
		is default the block's *absence*, since `Maybe(...).? or_else
		Material_Metallic_Roughness{}` -- what this proc's predecessor did --
		silently substitutes Odin's own zero value (metallic 0, roughness 0,
		base colour transparent black) for a material that never mentioned
		`pbrMetallicRoughness` at all, which is legal glTF and means exactly
		the same as an explicit block spelling out every default. So the
		absent case is spelled out here instead of folded into an `or_else`.
	*/
	pbr, has_pbr := gltf_material.metallic_roughness.?
	if !has_pbr {
		pbr = gltf.Material_Metallic_Roughness{
			base_color_factor = {1, 1, 1, 1},
			metallic_factor   = 1,
			roughness_factor  = 1,
		}
	}

	result.base_color = {
		f32(pbr.base_color_factor.x), f32(pbr.base_color_factor.y),
		f32(pbr.base_color_factor.z), f32(pbr.base_color_factor.w),
	}
	result.metallic  = f32(pbr.metallic_factor)
	result.roughness = f32(pbr.roughness_factor)

	if info, ok := pbr.base_color_texture.?; ok {
		if texture := resolve_texture(data, info.index, uploaded, .SRGB); texture != nil {
			result.textures.base         = texture
			result.textures.base_sampler = mbi.renderer.sprite_sampler
		}
	}

	if info, ok := pbr.metallic_roughness_texture.?; ok {
		result.textures.metal_rough = resolve_texture(data, info.index, uploaded, .UNORM)
	}

	/*
		Occlusion is its own glTF block, not part of `pbrMetallicRoughness`,
		and it may or may not name the same image as
		`metallic_roughness_texture` just above -- the common "ORM"
		convention packs all three (occlusion, roughness, metallic) into one
		image's R/G/B channels, and an equally legal file keeps occlusion in
		an image of its own. Either way this just asks `resolve_texture` for
		whatever image `occlusion_texture` names; its cache (keyed by image,
		not by which material field pointed at it) is what makes the
		shared-image case free -- this call returns the same GPU texture the
		metallic-roughness one above already uploaded rather than decoding
		the same bytes twice.
	*/
	if info, ok := gltf_material.occlusion_texture.?; ok {
		result.textures.occlusion = resolve_texture(data, info.index, uploaded, .UNORM)
	}

	if info, ok := gltf_material.emissive_texture.?; ok {
		result.textures.emissive = resolve_texture(data, info.index, uploaded, .SRGB)
	}

	return result
}

/*
	One glTF texture reference resolved to a GPU texture, shared with every
	other material field across the whole model that names the same image --
	see `read_material`'s own comment on `occlusion_texture` for why that
	sharing matters rather than being an incidental saving.

	`encoding` is the caller's to choose (`Texture_Encoding`, upload.odin):
	base colour and emissive are photometric colour and want `SRGB`;
	metallic-roughness and occlusion are numbers sampled back exactly and
	want `UNORM` -- see that type's own doc comment for the rule this
	follows. The cache below is keyed by image index alone, not by encoding,
	on the assumption that no asset this loader was built for reuses one
	image file as both a colour map and a data map; a file that did would get
	whichever encoding uploaded it first, silently -- a risk accepted rather
	than solved, since keying by (image, encoding) instead would cost a
	second GPU upload of the same bytes for every ordinary ORM texture, which
	is the common case, to guard against one this loader has not seen.

	The sampler every caller pairs this with is the nearest-neighbour one
	sprites use, for the same reason this loader always chose it before this
	job existed: every model this was written against declares `magFilter`
	9728, which is NEAREST.
*/
@(private)
resolve_texture :: proc(
	data:          ^gltf.Data,
	texture_index: gltf.Integer,
	uploaded:      ^map[gltf.Integer]^sdl.GPUTexture,
	encoding:      Texture_Encoding,
) -> ^sdl.GPUTexture {
	if int(texture_index) >= len(data.textures) do return nil
	source, has_source := data.textures[texture_index].source.?
	if !has_source do return nil

	if existing, found := uploaded[source]; found do return existing

	if int(source) >= len(data.images) do return nil

	// Embedded rather than a file beside the model, in every asset this was
	// built for -- the parser has already turned the base64 into bytes. An
	// image the parser could not resolve is still a string here.
	encoded, is_bytes := data.images[source].uri.([]byte)
	if !is_bytes {
		// A .glb keeps its images in the binary chunk instead: a buffer view
		// and a mime type, with no `uri` at all. That is the ordinary way a
		// GLB carries a texture rather than an edge case, so slice the bytes
		// out of the buffer the parser already copied.
		encoded, is_bytes = image_view_bytes(data, source)
	}
	if !is_bytes {
		log.error("model texture is not embedded, skipped")
		return nil
	}

	texture := decode_and_upload(encoded, encoding)
	if texture == nil do return nil

	uploaded[source] = texture
	return texture
}

/*
	An image's bytes out of the binary chunk.

	`uri` and `buffer_view` are the two ways glTF carries an image, and they are
	mutually exclusive: a `.gltf` writes a path or a base64 data URI, a `.glb`
	writes a view into the buffer chunk. Only the first was read here, so every
	GLB loaded as untextured geometry -- the mesh was fine, the material just
	never found its image.
*/
@(private)
image_view_bytes :: proc(data: ^gltf.Data, source: gltf.Integer) -> (bytes: []byte, ok: bool) {
	view_index := data.images[source].buffer_view.? or_return
	if int(view_index) >= len(data.buffer_views) do return nil, false
	view := data.buffer_views[view_index]

	if int(view.buffer) >= len(data.buffers) do return nil, false
	buffer := data.buffers[view.buffer].uri.([]byte) or_return

	start := int(view.byte_offset)
	end   := start + int(view.byte_length)
	if end > len(buffer) do return nil, false

	return buffer[start:end], true
}

// PNG or JPEG bytes to a GPU texture, through the same stb_image and the same
// staging path a sprite uses.
//
// `encoding` is the caller's (`resolve_texture`'s) to choose -- `SRGB` for a
// base-colour or emissive image, `UNORM` for a metallic-roughness or
// occlusion one. See `Texture_Encoding`'s own doc comment (upload.odin) for
// the rule and why decoding the latter through sRGB would be wrong rather
// than merely imprecise.
@(private)
decode_and_upload :: proc(encoded: []byte, encoding: Texture_Encoding) -> ^sdl.GPUTexture {
	width, height, channels: i32

	pixels := stbi.load_from_memory(raw_data(encoded), i32(len(encoded)), &width, &height, &channels, 4)
	if pixels == nil {
		log.errorf("could not decode a model texture: %s", stbi.failure_reason())
		return nil
	}
	defer stbi.image_free(pixels)

	// A texture that will not upload leaves the part untextured rather than
	// failing the load: the geometry is still worth having, and the caller
	// already treats a nil texture as "draw this flat".
	texture, err := upload_texture(pixels, width, height, encoding)
	if err != nil {
		log.errorf("could not upload a model texture: %v", err)
		return nil
	}

	return texture
}

// -----------------------------------------------------------------------
// Accessors
// -----------------------------------------------------------------------

/*
	Where one accessor's elements start, how far apart they are, and how many.

	A buffer view may declare a `byteStride`, and when it does that is the step
	between elements rather than the element's own size -- which is how
	interleaved vertex data is described, and also what Blockbench writes on
	tightly packed data where the two happen to be equal. Either way the stride
	is what to walk by; the element size is only the fallback when none is given.
*/
@(private)
accessor_span :: proc(data: ^gltf.Data, index: gltf.Integer) -> (bytes: []byte, stride, count: int, ok: bool) {
	if int(index) >= len(data.accessors) do return nil, 0, 0, false
	accessor := data.accessors[index]

	if _, sparse := accessor.sparse.?; sparse {
		log.error("sparse accessors are not supported, primitive skipped")
		return nil, 0, 0, false
	}

	view_index := accessor.buffer_view.? or_return
	if int(view_index) >= len(data.buffer_views) do return nil, 0, 0, false
	view := data.buffer_views[view_index]

	if int(view.buffer) >= len(data.buffers) do return nil, 0, 0, false
	buffer, is_bytes := data.buffers[view.buffer].uri.([]byte)
	if !is_bytes {
		log.error("model buffer was not resolved to bytes, primitive skipped")
		return nil, 0, 0, false
	}

	element := component_size(accessor.component_type) * component_count(accessor.type)
	stride   = int(view.byte_stride.? or_else gltf.Integer(element))
	count    = int(accessor.count)

	start := int(accessor.byte_offset) + int(view.byte_offset)
	if start + (count - 1) * stride + element > len(buffer) {
		log.error("accessor runs past the end of its buffer, primitive skipped")
		return nil, 0, 0, false
	}

	return buffer[start:], stride, count, true
}

@(private)
component_size :: proc(type: gltf.Component_Type) -> int {
	switch type {
	case .Byte, .Unsigned_Byte:   return 1
	case .Short, .Unsigned_Short: return 2
	case .Unsigned_Int, .Float:   return 4
	}
	return 0
}

@(private)
component_count :: proc(type: gltf.Accessor_Type) -> int {
	switch type {
	case .Scalar:  return 1
	case .Vector2: return 2
	case .Vector3: return 3
	case .Vector4: return 4
	case .Matrix2: return 4
	case .Matrix3: return 9
	case .Matrix4: return 16
	}
	return 0
}

/*
	Three floats per element, which is what glTF requires for positions,
	normals, translations and scales alike.

	The allocator is an argument because the two callers want different answers
	and nothing else about them differs. Vertex data is copied to the GPU
	immediately and never looked at again, so it takes the temp allocator;
	animation keyframes outlive the load and take a real one. This was two
	procedures that differed in that one word and in an error string.
*/
@(private)
read_vec3 :: proc(
	data: ^gltf.Data,
	index: gltf.Integer,
	allocator := context.temp_allocator,
) -> (out: [][3]f32, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float vec3 data, skipped")
		return nil, false
	}

	out = make([][3]f32, count, allocator)
	for i in 0 ..< count {
		out[i] = (cast(^[3]f32)&bytes[i * stride])^
	}

	return out, true
}

// A NORMAL that is not there. Legal, and it means flat shading off the
// triangle -- but there is nowhere to put a per-face normal in a vertex, so
// this fills in an up vector and lets the fixed light give a readable result.
// None of the files this was written for take this path.
@(private)
read_vec3_optional :: proc(
	data: ^gltf.Data, attributes: map[string]gltf.Integer, name: string, count: int,
) -> [][3]f32 {
	if index, present := attributes[name]; present {
		if values, ok := read_vec3(data, index); ok && len(values) >= count {
			return values
		}
	}

	log.infof("model primitive has no %s, substituting", name)

	out := make([][3]f32, count, context.temp_allocator)
	for i in 0 ..< count do out[i] = {0, 1, 0}
	return out
}

/*
	Texture coordinates, which may be floats or normalised integers.

	glTF allows a uv to be stored as unsigned bytes or shorts to save space, in
	which case the value runs over the whole range of the type and is divided
	down. Rare in an exported model and cheap to support.
*/
@(private)
read_vec2_optional :: proc(
	data: ^gltf.Data, attributes: map[string]gltf.Integer, name: string, count: int,
) -> [][2]f32 {
	out := make([][2]f32, count, context.temp_allocator)

	index, present := attributes[name]
	if !present do return out // all zeroes: untextured, and the tint carries it

	bytes, stride, available, ok := accessor_span(data, index)
	if !ok do return out

	type := data.accessors[index].component_type

	for i in 0 ..< min(count, available) {
		at := &bytes[i * stride]

		switch type {
		case .Float:
			out[i] = (cast(^[2]f32)at)^
		case .Unsigned_Byte:
			raw := (cast(^[2]u8)at)^
			out[i] = {f32(raw[0]) / 255, f32(raw[1]) / 255}
		case .Unsigned_Short:
			raw := (cast(^[2]u16)at)^
			out[i] = {f32(raw[0]) / 65535, f32(raw[1]) / 65535}
		case .Byte, .Short, .Unsigned_Int:
			fallthrough
		case:
			log.error("unsupported texture coordinate type")
			return out
		}
	}

	return out
}

/*
	A primitive's indices, widened to u32.

	glTF stores them as bytes, shorts or ints depending on how many vertices
	there are, and the GPU buffer is always 32-bit -- one index format for the
	whole renderer is worth more than the two bytes a short would save.

	A primitive with no indices at all is legal and means the vertices are
	already in order, so this makes the sequence it implies.
*/
@(private)
read_indices :: proc(data: ^gltf.Data, primitive: gltf.Mesh_Primitive, vertex_count: int) -> []u32 {
	index, present := primitive.indices.?

	if !present {
		out := make([]u32, vertex_count, context.temp_allocator)
		for i in 0 ..< vertex_count do out[i] = u32(i)
		return out
	}

	bytes, stride, count, ok := accessor_span(data, index)
	if !ok do return nil

	out := make([]u32, count, context.temp_allocator)
	type := data.accessors[index].component_type

	for i in 0 ..< count {
		at := &bytes[i * stride]

		switch type {
		case .Unsigned_Byte:  out[i] = u32((cast(^u8)at)^)
		case .Unsigned_Short: out[i] = u32((cast(^u16)at)^)
		case .Unsigned_Int:   out[i] = (cast(^u32)at)^
		case .Byte, .Short, .Float:
			fallthrough
		case:
			log.error("unsupported index type")
			return nil
		}
	}

	return out
}
