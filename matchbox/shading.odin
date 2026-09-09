package matchbox

/*
	Shading models
	--------------
	Which BRDF a material's surface runs. The values here and the numbers
	the shader reads them as (`shading_model_index`) have to agree with the
	`SHADING_*` defines in `shaders/brdf/contract.hlsli` -- nothing on the
	Odin side enforces that beyond this comment and the fact that getting it
	wrong picks the wrong lighting rather than failing to compile.

	Adding a new model touches exactly four places, not three -- P2b split the
	single `brdf_eval_<name>` P0 shipped into the three-piece contract
	`shaders/brdf/contract.hlsli` now describes, and the loop that used to
	live inside each model moved to shared code
	(`shade_lights`, `shaders/lighting_core.hlsli`). The four: a `.hlsli`
	under `shaders/brdf/` implementing `brdf_light_<name>` and
	`brdf_resolve_<name>`, a value here, one line in `brdf_light`'s switch,
	and one line in `brdf_resolve`'s switch (both in
	`shaders/lighting_core.hlsli`). Nothing else in shared code may assume
	which of these is running -- that is the property this whole rework
	exists to buy, see `lighting_rework.md` section 2 and section 2.1 for why
	the count moved from three to four.

	Two values so far. `lighting_plan.md` asks for five (PBR metallic-
	roughness, PBR specular-glossiness, toon, subsurface, on top of these
	two), and `Material`'s fields already carry the numbers those will read --
	see `material.odin`. They are not implemented yet because P0's job is the
	seam, not the models: `BLINN_PHONG` is today's shading ported unchanged,
	kept as the reference picture P0 is verified against, and `UNLIT` is what
	replaces the old fallback that ran whenever a scene had no lights (see
	`lighting_rework.md` section 1's first defect) -- lighting_rework.md
	section 6 is explicit that unlit is now a material's own choice rather
	than an accident of how many lights a scene happened to have.
*/
Shading_Model :: enum {
	BLINN_PHONG,
	UNLIT,
}

/*
	The value `shade_surface` (lighting_core.hlsli) switches on, and what
	`SHADING_BLINN_PHONG`/`SHADING_UNLIT` in brdf/contract.hlsli must equal.
	A `f32` because it travels inside a cbuffer float4, the same reason every
	other packed flag in this package is a float rather than the enum itself.

	Odin's own ordinal for the enum value, not a second switch matching this
	one against `SHADING_*` case by case -- a switch here would be a fourth
	place a new model has to touch, on top of the three this file's own doc
	comment promises. This is why the enum's declaration order has to track
	`shaders/brdf/contract.hlsli`'s `#define` values exactly: nothing checks
	that agreement beyond this comment and the fact that getting it wrong
	picks the wrong lighting rather than failing to compile.
*/
@(private)
shading_model_index :: proc(model: Shading_Model) -> f32 {
	return f32(model)
}
