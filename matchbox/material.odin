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

	**Every field for every model that will eventually exist was here from
	P0**, even though P0 itself implemented only two of the six
	`lighting_plan.md` asks for (see `shading.odin`). That was deliberate, not
	scope creep: it is what lets P2c add the other four shading models one at
	a time by touching the four places `shading.odin`'s own doc comment
	describes, without a fifth place to also widen `Material_Frag_Data`'s
	packed layout -- `metallic`, `roughness`, `specular` and `glossiness`,
	both PBR models' own fields, were already present and already reaching
	the shader, unread, before P2c touched a single `.hlsli`.
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
	// PBR's two parameterizations (brdf/pbr_metallic.hlsli,
	// brdf/pbr_specgloss.hlsli); bands/rim are toon's (P2); subsurface/
	// thickness are the SSS model's (P2); specular_power is Blinn-Phong's
	// (brdf/blinn_phong.hlsli).
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
	Cook-Torrance GGX under the metallic-roughness parameterization --
	`brdf/pbr_metallic.hlsli` is the shading model this reads into.
	`metallic` 0 is a dielectric (glass, plastic, wood -- most surfaces);
	1 is a bare metal, whose visible colour comes entirely from `base_color`
	tinting its specular reflection rather than from any diffuse term. Both
	0 and the roughness default below are legitimate values, not "unset" --
	see `material_normalized`'s own comment for why neither is defaulted at
	pack time the way `base_color` and `specular_power` are.
*/
create_material_pbr_metallic :: proc(
	base_color: [4]f32 = WHITE,
	metallic:   f32    = 0,
	roughness:  f32    = 0.5,
	emissive:   [3]f32 = {0, 0, 0},
	textures:   Material_Textures = {},
) -> Material {
	return Material{
		shading    = .PBR_METALLIC,
		base_color = base_color,
		metallic   = metallic,
		roughness  = roughness,
		emissive   = emissive,
		textures   = textures,
	}
}

/*
	The same Cook-Torrance BRDF as `create_material_pbr_metallic`, under
	glTF's specular-glossiness parameterization instead --
	`brdf/pbr_specgloss.hlsli` reads `specular` as the surface's reflectance
	at normal incidence directly (no metallic lerp) and `glossiness` as the
	inverse of roughness. `specular`'s default, 0.04, is the same "unspecified
	dielectric" stand-in `pbr_metallic.hlsli` derives internally -- this
	parameterization has no metallic term to derive it from, so a caller
	states it directly instead.
*/
create_material_pbr_specgloss :: proc(
	base_color: [4]f32 = WHITE,
	specular:   [3]f32 = {0.04, 0.04, 0.04},
	glossiness: f32    = 0.5,
	emissive:   [3]f32 = {0, 0, 0},
	textures:   Material_Textures = {},
) -> Material {
	return Material{
		shading    = .PBR_SPECGLOSS,
		base_color = base_color,
		specular   = specular,
		glossiness = glossiness,
		emissive   = emissive,
		textures   = textures,
	}
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
	emissive:   [4]f32, // xyz emissive colour,                  w specular_power (Blinn-Phong)
	params:     [4]f32, // x metallic, y roughness, z bands (toon, P2), w rim (toon, P2)
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

	**`metallic`, `roughness` and `glossiness` are deliberately not in here**,
	and they are why this rule is a per-field judgement rather than a sweep
	over every number. Zero metallic is a dielectric, which is most surfaces;
	zero roughness is a perfect mirror (clamped away from the literal 0
	inside `brdf/pbr_metallic.hlsli` for a numerical reason, not a semantic
	one -- see that file's own comment); zero glossiness is "as rough as
	specular-glossiness can express", the same real answer from the other
	parameterization's own side, which `brdf/pbr_specgloss.hlsli` reads
	directly. `specular` (spec-gloss's own `f0`) is judged the same way in
	`create_material_pbr_specgloss`'s own doc comment rather than swept here:
	a caller who wants a material with genuinely zero specular reflectance
	means exactly that. The remaining P2c fields -- `bands`, `rim`,
	`subsurface`, `thickness` -- are unread by any model this far into P2c;
	whichever of them turn out to have no sensible zero get added here by the
	model that starts reading them, the same way these were.
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
