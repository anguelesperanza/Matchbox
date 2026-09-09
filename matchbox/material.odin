package matchbox

/*
	Material
	--------
	What a surface is made of, as far as shading cares.

	There was no material type in Matchbox before this: a `Model_Part` carried
	a single tint-multiplied texture and nothing else, and `model_load.odin`
	read a glTF material's base-colour texture and threw the rest away. This
	is the replacement -- one struct, flat rather than a union of per-model
	parameters, because a cbuffer wants a flat layout and a union would have
	to be flattened for the GPU anyway. Which fields mean anything is
	documented per shading model in the .hlsli files under `shaders/brdf`; a field a given
	model does not read rides along unread, the same way `Light.cone` already
	does for a light that is not a spot.

	**Every field for every model that will eventually exist is here now**,
	even though P0 implements only two of the six `lighting_plan.md` asks for
	(see `shading.odin`). That is deliberate, not scope creep: it is what lets
	a later shading model be added by touching exactly three places (a
	`.hlsli`, an enum value, one dispatcher line) rather than a fourth --
	`Material_Frag_Data` below already has room for every model's numbers, so
	P2's workers never touch the packed layout at all.
*/

import sdl "vendor:sdl3"

/*
	The textures a material may bind. `base` is the only one any loader fills
	in today -- `model_load.odin` still reads a glTF material's base-colour
	texture alone, exactly as it did before this rework (see D8, and P2's
	"model_load.odin reads the full glTF material" for when that changes).
	The rest exist so that day is a loader change and not also a struct
	change.

	`base_sampler` travels with `base` rather than living on `Model_Part`,
	because a texture and the sampler it was authored for are one decision --
	glTF's own per-texture sampler is what `material_texture` (model_load.odin)
	already reads.
*/
Material_Textures :: struct {
	base:         ^sdl.GPUTexture,
	base_sampler: ^sdl.GPUSampler,

	// Unused until P2's loader work reads them. Present now so that work is
	// additive to this struct rather than a second pass over every caller.
	metal_rough: ^sdl.GPUTexture,
	normal:      ^sdl.GPUTexture,
	occlusion:   ^sdl.GPUTexture,
	emissive:    ^sdl.GPUTexture,
}

Material :: struct {
	shading:    Shading_Model,
	base_color: [4]f32,

	// Per-model parameters, flat rather than a union: see this file's own
	// top comment for why. Metallic-roughness and specular-glossiness are
	// PBR's two parameterizations (P2); bands/rim are toon's; subsurface/
	// thickness are the SSS model's; specular_power is Blinn-Phong's, and is
	// the one already read in P0 -- see brdf/blinn_phong.hlsli.
	metallic:       f32,
	roughness:      f32,
	specular:       [3]f32,
	glossiness:     f32,
	specular_power: f32,
	bands:          f32,
	rim:            f32,
	subsurface:     [3]f32,
	thickness:      f32,
	emissive:       [3]f32,

	textures: Material_Textures,
}

/*
	The values every generated shape (`create_cube_model` and friends) and
	every untextured glTF part draws with -- lit, white, the same specular
	exponent PsxGame's shader always used. A named constant of struct type
	rather than a loose one, per CLAUDE.md; `create_material_phong`'s own
	defaults and `upload_mesh`'s generated parts both read it, so "what does
	an untouched Model_Part look like" is answered in one place.
*/
MATERIAL_DEFAULTS :: Material{shading = .BLINN_PHONG, base_color = {1, 1, 1, 1}, specular_power = 16}

// A lit, Blinn-Phong-shaded material. What every model was, implicitly,
// before this file existed -- this just gives that a name and lets the
// numbers vary per part rather than being baked into the shader.
create_material_phong :: proc(
	base_color:     [4]f32 = WHITE,
	specular_power: f32    = 16,
	textures:       Material_Textures = {},
) -> Material {
	return Material{
		shading        = .BLINN_PHONG,
		base_color     = base_color,
		specular_power = specular_power,
		textures       = textures,
	}
}

/*
	A material no light reaches -- `shade_surface` (lighting_core.hlsli)
	returns `base_color` for one of these regardless of what the scene's
	lights or `Lighting_Settings.enabled` say, the same as it does for every
	surface when lighting is off scene-wide. See that struct's own doc
	comment on the two ways to end up with an unlit picture.
*/
create_material_unlit :: proc(base_color: [4]f32 = WHITE, textures: Material_Textures = {}) -> Material {
	return Material{shading = .UNLIT, base_color = base_color, textures = textures}
}

/*
	112 bytes: the wire form of a `Material` plus the one thing that is not a
	material property at all -- `tint`, `draw_model`'s own per-call multiplier,
	carried here because both are pushed together, once per part, in the same
	fragment uniform slot `Mesh_Frag_Data` used to occupy alone.

	Every member a float4, for the packing reason `Light_Uniform` already
	documents: HLSL pads a vector that would straddle a 16-byte boundary, the
	padding is invisible from here, and float4-everywhere makes the two sides
	agree by construction instead of by careful counting.
*/
Material_Frag_Data :: struct #align(16) {
	tint:       [4]f32, // draw_model's own multiplier, not a material property
	base_color: [4]f32,
	specular:   [4]f32, // xyz specular colour (spec-gloss, P2), w glossiness (spec-gloss, P2)
	emissive:   [4]f32, // xyz emissive colour (P2),             w specular_power (Blinn-Phong)
	params:     [4]f32, // x metallic (P2), y roughness (P2), z bands (toon, P2), w rim (toon, P2)
	subsurface: [4]f32, // xyz subsurface tint (P2),             w thickness (P2)
	shading:    [4]f32, // x shading_model_index -- see shading.odin.  y-w unused
}

/*
	Zero means the default, for the two fields here that have no sensible
	zero -- see `lighting_settings_normalized` (lighting.odin) for the rule
	and the reasoning behind it.

	This is what makes a hand-built `Material{shading = .BLINN_PHONG}` draw
	something, rather than an invisible surface with a blown-out specular
	highlight over all of it.

	**Applied at pack time rather than stored back**, which is the one place
	this rule works differently from `Lighting_Settings` and
	`Shadow_Settings`. Those two are Matchbox's own state and are normalized
	when they are handed over, so a read reports what runs. A `Material`
	belongs to whoever built it -- it lives on a caller's `Model_Part`, and
	`draw_model` takes its `Model` by value -- so there is nowhere to store a
	normalized copy that the caller would ever see. Packing is the last point
	the value passes through before the GPU, so it is where the fixup goes.

	**`metallic` and `roughness` are deliberately not in here**, and they are
	why this rule is a per-field judgement rather than a sweep over every
	number. Both have legitimate zeroes under the metallic-roughness model
	P2 adds: zero metallic is a dielectric, which is most surfaces, and zero
	roughness is a perfect mirror. Defaulting either would make a value
	somebody meant unreachable. The remaining P2 fields -- `specular`,
	`glossiness`, `bands`, `rim`, `subsurface`, `thickness`, `emissive` --
	are unread by any model P0 or P1 built; whichever of them turn out to
	have no sensible zero get added here by the phase that starts reading
	them, and the ones that do are named here as exceptions, the same way
	these two are.
*/
@(private)
material_normalized :: proc(material: Material) -> Material {
	m := material

	// All-zero is an invisible surface, which no caller means -- and it
	// cannot collide with a legitimately black one, since that is
	// {0, 0, 0, 1} and carries its alpha. Body.tint (types.odin) is the
	// same sentinel and the same argument.
	if m.base_color == {0, 0, 0, 0} do m.base_color = MATERIAL_DEFAULTS.base_color

	// pow(x, 0) is 1 for every x, so a zero exponent is not a dull highlight
	// -- it is a full-strength one across the entire surface.
	if m.specular_power == 0 do m.specular_power = MATERIAL_DEFAULTS.specular_power

	return m
}

// `material`'s numbers plus this draw's own tint, packed for the GPU.
@(private)
material_frag_data :: proc(material: Material, tint: [4]f32) -> Material_Frag_Data {
	m := material_normalized(material)

	return Material_Frag_Data{
		tint       = tint,
		base_color = m.base_color,
		specular   = {m.specular.x, m.specular.y, m.specular.z, m.glossiness},
		emissive   = {m.emissive.x, m.emissive.y, m.emissive.z, m.specular_power},
		params     = {m.metallic, m.roughness, m.bands, m.rim},
		subsurface = {m.subsurface.x, m.subsurface.y, m.subsurface.z, m.thickness},
		shading    = {shading_model_index(m.shading), 0, 0, 0},
	}
}
