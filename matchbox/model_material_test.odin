package matchbox

/*
	glTF material loading -- the arithmetic
	----------------------------------------
	`read_material` (model_load.odin) is a pure transformation: a
	`gltf2.Material` (or its absence) in, a `matchbox.Material` out, with a
	texture cache it either finds something in or does not. Every case below
	is built and asserted without a GPU -- `resolve_texture` never reaches the
	device unless it actually has to decode and upload bytes, and every test
	here either supplies no texture reference at all or pre-seeds the cache so
	the lookup succeeds before that point.

	**What is not covered here.** Actually decoding an image and uploading it
	needs `mbi.renderer.device`, which no test in this package stands up --
	see `upload_texture` (upload.odin) and its callers. That path is what a
	real load exercises end to end; it is not measured by anything below.
*/

import "core:encoding/json"
import "core:testing"

import sdl "vendor:sdl3"

import gltf "./gltf2"

// -----------------------------------------------------------------------
// No material, or one this file's own list does not reach
// -----------------------------------------------------------------------

@(test)
test_no_material_index_gives_matchbox_defaults :: proc(t: ^testing.T) {
	data := gltf.Data{}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, nil, &uploaded)

	testing.expect(t, m == MATERIAL_DEFAULTS,
		"a primitive with no material at all must draw exactly like a generated shape")
}

@(test)
test_material_index_past_the_file_gives_matchbox_defaults :: proc(t: ^testing.T) {
	data := gltf.Data{materials = {}}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m == MATERIAL_DEFAULTS,
		"a material index the file's own list does not reach must not read past the end of it")
}

// -----------------------------------------------------------------------
// glTF's own defaults, which are not Matchbox's
// -----------------------------------------------------------------------

@(test)
test_material_with_no_pbr_block_gets_gltf_defaults_not_matchbox_ones :: proc(t: ^testing.T) {
	/*
		A material entry that exists but says nothing about
		pbrMetallicRoughness at all -- legal glTF, and the spec's own answer
		is metallic 1, roughness 1, base colour opaque white. Matchbox's own
		create_material_pbr_metallic defaults (metallic 0, roughness 0.5) are
		a hand-authoring choice for a different call path and must not leak
		into a reading of the file.
	*/
	data := gltf.Data{materials = {gltf.Material{}}}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m.metallic == 1, "an absent pbrMetallicRoughness block means metallic 1, per the glTF spec")
	testing.expect(t, m.roughness == 1, "an absent pbrMetallicRoughness block means roughness 1, per the glTF spec")
	testing.expect(t, m.base_color == [4]f32{1, 1, 1, 1}, "an absent pbrMetallicRoughness block means opaque white")
	testing.expect(t, m.metallic != create_material_pbr_metallic().metallic,
		"the spec default and Matchbox's own hand-authoring default must not be confused")
}

@(test)
test_pbr_block_present_but_factors_unstated_still_defaults_to_one :: proc(t: ^testing.T) {
	// The parser (gltf2.pbr_metallic_roughness_parse) is what actually
	// applies this default when the block itself is present; this pins that
	// behaviour from the loader's own side so a parser change would be
	// caught here too, not just inside gltf2's own tests.
	data := gltf.Data{materials = {
		gltf.Material{metallic_roughness = gltf.Material_Metallic_Roughness{
			metallic_factor = 1, roughness_factor = 1, base_color_factor = {1, 1, 1, 1},
		}},
	}}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m.metallic == 1 && m.roughness == 1, "a present-but-empty pbr block still means metallic/roughness 1")
}

// -----------------------------------------------------------------------
// Factors without textures
// -----------------------------------------------------------------------

@(test)
test_factors_with_no_textures_carry_through_with_no_shading_change :: proc(t: ^testing.T) {
	data := gltf.Data{materials = {
		gltf.Material{
			emissive_factor = {1, 0.5, 0},
			metallic_roughness = gltf.Material_Metallic_Roughness{
				base_color_factor = {0.2, 0.4, 0.6, 0.8},
				metallic_factor   = 0.3,
				roughness_factor  = 0.7,
			},
		},
	}}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m.base_color == [4]f32{0.2, 0.4, 0.6, 0.8}, "base_color_factor must reach Material.base_color")
	testing.expect(t, m.metallic == 0.3, "metallic_factor must reach Material.metallic")
	testing.expect(t, m.roughness == 0.7, "roughness_factor must reach Material.roughness")
	testing.expect(t, m.emissive == [3]f32{1, 0.5, 0}, "emissive_factor must reach Material.emissive")

	testing.expect(t, m.textures.base == nil && m.textures.metal_rough == nil &&
		m.textures.occlusion == nil && m.textures.emissive == nil,
		"no texture reference in the file must mean no texture on the Material")

	/*
		This assertion used to run the other way, and the reversal is
		deliberate -- see `lighting_rework.md` section 7.6 and
		`read_material`'s own doc comment. The reasoning it was written under
		was that `lighting_plan.md`'s "the consumer selects" principle meant
		the loader must not pick a shading model. But a `pbrMetallicRoughness`
		block is the *file* stating what the surface is; assigning Blinn-Phong
		to it is not declining to choose, it is choosing on the game's behalf
		while discarding what the file said -- and it left every factor
		asserted above populated for a model that reads none of them.
	*/
	testing.expect(t, m.shading == .PBR_METALLIC,
		"a material declaring metallic-roughness must load as PBR_METALLIC, not as the generated-shape default")
}

// -----------------------------------------------------------------------
// Textures: shared images and distinct images
// -----------------------------------------------------------------------

@(test)
test_occlusion_sharing_the_metallic_roughness_image_reuses_the_upload :: proc(t: ^testing.T) {
	/*
		The "ORM" convention: one image, referenced by both
		metallicRoughnessTexture and occlusionTexture. resolve_texture's cache
		is keyed by image (source), not by which material field pointed at
		it, so pre-seeding the cache for that one image and confirming both
		fields come back as the exact same pointer tests the real sharing
		path without ever reaching decode_and_upload or a GPU.
	*/
	shared_texture: sdl.GPUTexture
	fake := &shared_texture

	image_index := gltf.Integer(0)

	data := gltf.Data{
		textures = {gltf.Texture{source = image_index}},
		materials = {
			gltf.Material{
				metallic_roughness = gltf.Material_Metallic_Roughness{
					base_color_factor          = {1, 1, 1, 1},
					metallic_factor             = 1,
					roughness_factor            = 1,
					metallic_roughness_texture  = gltf.Texture_Info{index = 0},
				},
				occlusion_texture = gltf.Material_Occlusion_Texture_Info{index = 0, strength = 1},
			},
		},
	}

	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)
	uploaded[image_index] = fake

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m.textures.metal_rough == fake, "metal_rough must resolve to the pre-cached image")
	testing.expect(t, m.textures.occlusion == fake, "occlusion naming the same image must reuse the same GPU texture")
}

@(test)
test_occlusion_and_metallic_roughness_in_different_images_stay_distinct :: proc(t: ^testing.T) {
	mr_texture, occ_texture: sdl.GPUTexture
	mr_fake, occ_fake := &mr_texture, &occ_texture

	data := gltf.Data{
		textures = {
			gltf.Texture{source = gltf.Integer(0)}, // metallic-roughness image
			gltf.Texture{source = gltf.Integer(1)}, // occlusion's own image
		},
		materials = {
			gltf.Material{
				metallic_roughness = gltf.Material_Metallic_Roughness{
					base_color_factor         = {1, 1, 1, 1},
					metallic_factor            = 1,
					roughness_factor           = 1,
					metallic_roughness_texture = gltf.Texture_Info{index = 0},
				},
				occlusion_texture = gltf.Material_Occlusion_Texture_Info{index = 1, strength = 1},
			},
		},
	}

	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)
	uploaded[gltf.Integer(0)] = mr_fake
	uploaded[gltf.Integer(1)] = occ_fake

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m.textures.metal_rough == mr_fake, "metal_rough must resolve to its own image")
	testing.expect(t, m.textures.occlusion == occ_fake, "occlusion must resolve to its own image, not metal_rough's")
	testing.expect(t, m.textures.metal_rough != m.textures.occlusion,
		"two different glTF images must not collapse into the same GPU texture")
}

@(test)
test_base_color_and_emissive_textures_resolve_independently :: proc(t: ^testing.T) {
	base_texture, emissive_texture: sdl.GPUTexture
	base_fake, emissive_fake := &base_texture, &emissive_texture

	data := gltf.Data{
		textures = {
			gltf.Texture{source = gltf.Integer(0)},
			gltf.Texture{source = gltf.Integer(1)},
		},
		materials = {
			gltf.Material{
				emissive_factor   = {1, 1, 1},
				emissive_texture  = gltf.Texture_Info{index = 1},
				metallic_roughness = gltf.Material_Metallic_Roughness{
					base_color_factor   = {1, 1, 1, 1},
					metallic_factor      = 1,
					roughness_factor     = 1,
					base_color_texture   = gltf.Texture_Info{index = 0},
				},
			},
		},
	}

	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)
	uploaded[gltf.Integer(0)] = base_fake
	uploaded[gltf.Integer(1)] = emissive_fake

	m := read_material(&data, 0, &uploaded)

	testing.expect(t, m.textures.base == base_fake, "base colour must resolve to its own image")
	testing.expect(t, m.textures.base_sampler == mbi.renderer.sprite_sampler,
		"a resolved base texture must carry the sampler every glTF texture in this loader uses")
	testing.expect(t, m.textures.emissive == emissive_fake, "emissive must resolve to its own image")
}

// -----------------------------------------------------------------------
// resolve_texture's own guards
// -----------------------------------------------------------------------

@(test)
test_resolve_texture_out_of_range_index_returns_nil_without_touching_the_gpu :: proc(t: ^testing.T) {
	data := gltf.Data{textures = {}}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	texture := resolve_texture(&data, 0, &uploaded, .UNORM)

	testing.expect(t, texture == nil, "a texture index past the file's own list must come back nil, not panic")
}

@(test)
test_resolve_texture_with_no_source_image_returns_nil :: proc(t: ^testing.T) {
	// A glTF texture may name a sampler with no source image at all --
	// legal, and pointless, but not a crash.
	data := gltf.Data{textures = {gltf.Texture{}}}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	texture := resolve_texture(&data, 0, &uploaded, .UNORM)

	testing.expect(t, texture == nil, "a texture with no source image must come back nil")
}

// -----------------------------------------------------------------------
// Which shading model a loaded material declares itself to be
// -----------------------------------------------------------------------

/*
	The half of `read_material` that decides `shading` rather than the
	numbers -- see that proc's own doc comment for why honouring the file is
	the default and `load_model`'s `shading` parameter is the override.

	`MATERIAL_DEFAULTS` is still Blinn-Phong, and these tests are careful not
	to conflate the two cases: a primitive with *no* material is a generated
	shape by another name and keeps that default, while a primitive with a
	real glTF material gets what that material declares.
*/

@(test)
test_a_glTF_material_declares_itself_metallic_roughness :: proc(t: ^testing.T) {
	materials := [1]gltf.Material{{
		metallic_roughness = gltf.Material_Metallic_Roughness{
			base_color_factor = {1, 1, 1, 1},
			metallic_factor   = 1,
			roughness_factor  = 1,
		},
	}}
	data := gltf.Data{materials = materials[:]}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, gltf.Integer(0), &uploaded)

	testing.expect(t, m.shading == .PBR_METALLIC,
		"a pbrMetallicRoughness block is the file saying what it is; loading it as Blinn-Phong would discard that")
}

@(test)
test_a_material_without_a_pbr_block_is_still_metallic_roughness :: proc(t: ^testing.T) {
	// Legal glTF, and it means every pbrMetallicRoughness default spelled
	// out -- not "this material has no parameterization". See read_material's
	// own comment on the absent block.
	materials := [1]gltf.Material{{}}
	data := gltf.Data{materials = materials[:]}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, gltf.Integer(0), &uploaded)

	testing.expect(t, m.shading == .PBR_METALLIC,
		"an absent pbrMetallicRoughness block is the spec's defaults, not the absence of a parameterization")
}

@(test)
test_khr_materials_unlit_loads_as_unlit :: proc(t: ^testing.T) {
	extensions := make(json.Object)
	defer delete(extensions)
	extensions["KHR_materials_unlit"] = json.Object{}

	materials := [1]gltf.Material{{extensions = extensions}}
	data := gltf.Data{materials = materials[:]}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, gltf.Integer(0), &uploaded)

	testing.expect(t, m.shading == .UNLIT,
		"KHR_materials_unlit is a rendering hint with no parameters -- its presence is the whole of it")
}

@(test)
test_an_unrelated_extension_does_not_change_the_shading_model :: proc(t: ^testing.T) {
	/*
		The check is a lookup of one key, not "does this material carry any
		extension at all" -- a file with KHR_texture_transform or a VRM block
		on its materials is ordinary and must not be read as unlit.
	*/
	extensions := make(json.Object)
	defer delete(extensions)
	extensions["KHR_texture_transform"] = json.Object{}

	materials := [1]gltf.Material{{}}
	materials[0].extensions = extensions
	data := gltf.Data{materials = materials[:]}
	uploaded := make(map[gltf.Integer]^sdl.GPUTexture)
	defer delete(uploaded)

	m := read_material(&data, gltf.Integer(0), &uploaded)

	testing.expect(t, m.shading == .PBR_METALLIC,
		"only KHR_materials_unlit means unlit; any other extension leaves the parameterization alone")
}
