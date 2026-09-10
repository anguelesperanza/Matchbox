package matchbox

/*
	Zero means the default -- the arithmetic
	-----------------------------------------
	`lighting_settings_normalized` (lighting.odin), `shadow_settings_normalized`
	(shadow.odin) and `material_normalized` (material.odin) are the three
	places the rule is applied. See the first of those for the rule itself and
	why it exists.

	Pure conversions, so no GPU is needed -- the same reason `light_test.odin`
	can check `light_uniform`'s packing without one.

	**What is actually worth testing here is the half that does nothing.** A
	rule that replaces zeroes is easy to write and easy to over-apply, and an
	over-applied one is worse than none: it makes a value somebody deliberately
	wrote unreachable, silently, with no way to ask for it back. So every
	default below is paired with a test that a legitimate zero survives, and
	the exceptions the rule deliberately does not cover -- `metallic`,
	`roughness`, `Ambient{}`, `Fog{}`, a shadow struct that is switched off --
	get a test each saying so.
*/

import "core:testing"

// -----------------------------------------------------------------------
// Lighting_Settings
// -----------------------------------------------------------------------

@(test)
test_zero_exposure_becomes_one :: proc(t: ^testing.T) {
	// The literal that rendered nine examples black before this rule existed.
	s := lighting_settings_normalized(Lighting_Settings{enabled = true})

	testing.expect(t, s.exposure == 1, "an unset exposure must default to 1, not multiply the scene to black")
}

@(test)
test_an_exposure_someone_meant_survives :: proc(t: ^testing.T) {
	dim    := lighting_settings_normalized(Lighting_Settings{enabled = true, exposure = 0.5})
	bright := lighting_settings_normalized(Lighting_Settings{enabled = true, exposure = 4})

	testing.expect(t, dim.exposure == 0.5,  "a deliberate exposure below 1 must not be treated as unset")
	testing.expect(t, bright.exposure == 4, "a deliberate exposure above 1 must be left alone")
}

@(test)
test_lighting_fields_with_legitimate_zeroes_are_left_alone :: proc(t: ^testing.T) {
	s := lighting_settings_normalized(Lighting_Settings{enabled = true})

	// Each of these is a real answer, not a forgotten field: no ambient light,
	// no fog, no tone mapping. The rule must not invent any of them.
	testing.expect(t, s.ambient.color == {0, 0, 0, 0}, "an unset Ambient must stay no ambient light")
	testing.expect(t, !s.fog.enabled,                  "an unset Fog must stay off")
	testing.expect(t, s.tonemap == .NONE,              "an unset tonemap must stay NONE")
	testing.expect(t, s.pipeline == .FORWARD,          "an unset pipeline must stay FORWARD")
}

@(test)
test_lighting_disabled_is_not_treated_as_unset :: proc(t: ^testing.T) {
	s := lighting_settings_normalized(Lighting_Settings{})

	testing.expect(t, !s.enabled, "a scene that says it is not lit must stay that way")
}

// -----------------------------------------------------------------------
// Shadow_Settings
// -----------------------------------------------------------------------

@(test)
test_enabled_shadows_fill_in_their_numbers :: proc(t: ^testing.T) {
	// `shadows = {enabled = true}` has to be a working way to ask for
	// shadows, rather than a 0x0 map inside a frustum of no width and no
	// depth.
	s := shadow_settings_normalized(Shadow_Settings{enabled = true})

	testing.expect(t, s.resolution == SHADOW_DEFAULTS.resolution, "a 0 resolution would be a 0x0 shadow map")
	testing.expect(t, s.extent     == SHADOW_DEFAULTS.extent,     "a 0 extent would be a frustum of no width")
	testing.expect(t, s.near       == SHADOW_DEFAULTS.near,       "a 0 near plane would be degenerate")
	testing.expect(t, s.far        == SHADOW_DEFAULTS.far,        "a 0 far plane would be degenerate")
	testing.expect(t, s.bias       == SHADOW_DEFAULTS.bias,       "a 0 bias (both fields) is acne -- see Shadow_Bias's own comment")
	testing.expect(t, s.light_size == SHADOW_DEFAULTS.light_size, "a 0 PCSS light size collapses the penumbra to nothing")
	testing.expect(t, s.cascade_count == SHADOW_DEFAULTS.cascade_count, "a 0 cascade count is 0 shadow maps for a light told to cast one")
}

// bias's two fields are each their own per-field judgement -- shadow.odin's
// own comment on Shadow_Bias explains why -- so a caller overriding only one
// of them must not have the other silently defaulted alongside it.
@(test)
test_shadow_bias_fields_default_independently :: proc(t: ^testing.T) {
	depth_only := shadow_settings_normalized(Shadow_Settings{enabled = true, bias = {depth = 0.01}})
	testing.expect(t, depth_only.bias.depth == 0.01, "a deliberate depth bias must survive")
	testing.expect(t, depth_only.bias.normal_offset == SHADOW_DEFAULTS.bias.normal_offset,
		"an unset normal-offset must still default even when depth was set")

	offset_only := shadow_settings_normalized(Shadow_Settings{enabled = true, bias = {normal_offset = 0.1}})
	testing.expect(t, offset_only.bias.normal_offset == 0.1, "a deliberate normal-offset must survive")
	testing.expect(t, offset_only.bias.depth == SHADOW_DEFAULTS.bias.depth,
		"an unset depth bias must still default even when normal-offset was set")
}

@(test)
test_shadow_cascade_count_is_clamped :: proc(t: ^testing.T) {
	over := shadow_settings_normalized(Shadow_Settings{enabled = true, cascade_count = MAX_CASCADES + 5})
	testing.expect(t, over.cascade_count == MAX_CASCADES, "cascade_count must not exceed MAX_CASCADES")

	under := shadow_settings_normalized(Shadow_Settings{enabled = true, cascade_count = -3})
	testing.expect(t, under.cascade_count == 1, "cascade_count must not go below 1")
}

@(test)
test_shadow_numbers_someone_meant_survive :: proc(t: ^testing.T) {
	asked := Shadow_Settings{
		enabled = true, technique = .PCF, resolution = 2048, extent = 5, near = 0.5, far = 100,
		bias = {depth = 0.01, normal_offset = 0.2}, light_size = 0.3,
		cascade_count = 3, cascade_split_lambda = 0.8,
	}
	s := shadow_settings_normalized(asked)

	testing.expect(t, s == asked, "a fully specified Shadow_Settings must come back untouched")
}

@(test)
test_disabled_shadows_keep_their_zeroes :: proc(t: ^testing.T) {
	/*
		Not filled in and then ignored. A caller that switches shadows off,
		writes zeroes while they are off, and switches them back on should get
		its own numbers back -- so "off" means the whole struct is left as
		written, not that the numbers are quietly rewritten behind it.
	*/
	s := shadow_settings_normalized(Shadow_Settings{})

	testing.expect(t, !s.enabled,       "shadows must stay off")
	testing.expect(t, s.resolution == 0, "a switched-off shadow struct must not be filled in")
	testing.expect(t, s.extent     == 0, "a switched-off shadow struct must not be filled in")
	testing.expect(t, s.bias       == Shadow_Bias{}, "a switched-off shadow struct must not be filled in")
	testing.expect(t, s.cascade_count == 0, "a switched-off shadow struct must not be filled in")
}

@(test)
test_shadows_normalize_through_lighting_settings :: proc(t: ^testing.T) {
	// The nesting is the path a real caller takes -- set_lighting normalizes
	// the whole tree, not just its own top level.
	s := lighting_settings_normalized(Lighting_Settings{enabled = true, shadows = {enabled = true}})

	testing.expect(t, s.shadows.resolution == SHADOW_DEFAULTS.resolution,
		"a nested Shadow_Settings must be normalized too, not only the top level")
}

// -----------------------------------------------------------------------
// Material
// -----------------------------------------------------------------------

@(test)
test_zero_material_draws_something :: proc(t: ^testing.T) {
	m := material_normalized(Material{shading = .BLINN_PHONG})

	testing.expect(t, m.base_color == WHITE, "an all-zero base_color would be an invisible surface")
	testing.expect(t, m.specular_power == MATERIAL_DEFAULTS.specular_power,
		"pow(x, 0) is 1 everywhere -- a zero exponent is a blown-out highlight, not a dull one")
	testing.expect(t, m.bands == MATERIAL_DEFAULTS.bands,
		"brdf/toon.hlsli guards bands with max(bands, 1) -- an un-set zero would silently become one flat band rather than the toon material a caller likely meant")
}

@(test)
test_a_black_material_stays_black :: proc(t: ^testing.T) {
	/*
		The sentinel test, and the reason the check is on all four components
		rather than on rgb alone. A material somebody wants black is
		{0, 0, 0, 1} and carries its alpha, so it cannot be confused with one
		nobody filled in -- exactly the argument Body.tint (types.odin) makes
		for the same sentinel.
	*/
	m := material_normalized(Material{shading = .BLINN_PHONG, base_color = {0, 0, 0, 1}})

	testing.expect(t, m.base_color == [4]f32{0, 0, 0, 1},
		"a deliberately black opaque material must not be turned white")
}

@(test)
test_material_exceptions_keep_their_zeroes :: proc(t: ^testing.T) {
	/*
		The rule is a per-field judgement, not a sweep, and this file's own
		material_normalized comment names each of these as a value somebody
		can mean rather than an unset field: zero metallic is a dielectric
		(most surfaces in the world), zero roughness is a perfect mirror,
		zero glossiness is as rough as specular-glossiness can express, and
		zero specular/subsurface/thickness/rim are each a real "none of this"
		a caller can ask for on purpose. Defaulting any of them would put a
		value somebody meant out of reach -- `bands`, checked separately in
		test_zero_material_draws_something, is the one P2c field that fails
		this test instead.
	*/
	m := material_normalized(Material{shading = .BLINN_PHONG})

	testing.expect(t, m.metallic   == 0, "zero metallic is a dielectric, not an unset field")
	testing.expect(t, m.roughness  == 0, "zero roughness is a mirror, not an unset field")
	testing.expect(t, m.glossiness == 0, "zero glossiness is as rough as spec-gloss can express, not an unset field")
	testing.expect(t, m.specular   == [3]f32{0, 0, 0}, "zero specular is a real F0, not an unset field")
	testing.expect(t, m.subsurface == [3]f32{0, 0, 0}, "zero subsurface is no translucent tint, not an unset field")
	testing.expect(t, m.thickness  == 0, "zero thickness is as thin as the SSS model can express, not an unset field")
	testing.expect(t, m.rim        == 0, "zero rim is no rim light, not an unset field")
}

@(test)
test_material_numbers_someone_meant_survive :: proc(t: ^testing.T) {
	// bands joined specular_power here in P2c -- see material_normalized's
	// own comment for why a zero bands is treated as unset while roughness,
	// metallic, glossiness, specular, subsurface, thickness and rim are not
	// -- so a "fully specified" material for this test has to give bands a
	// real value too, the same reason specular_power already had to.
	asked := Material{shading = .UNLIT, base_color = {0.2, 0.4, 0.6, 0.5}, specular_power = 64, bands = 8}
	m     := material_normalized(asked)

	testing.expect(t, m == asked, "a fully specified Material must come back untouched")
}
