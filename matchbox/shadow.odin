package matchbox

import sdl "vendor:sdl3"

/*
	Shadows -- the contract
	------------------------
	The technique-agnostic shapes: what a shadow technique is chosen from, and
	the numbers every technique needs regardless of which one is running. The
	pass orchestration for the one technique P0 implements is in
	`shadow_standard.odin`; the shader half of it is `shaders/shadow/pcf.hlsli`
	behind `shaders/shadow/contract.hlsli`.

	**Directional and spot, not point.** A point light's shadow needs a
	cubemap -- six depth renders instead of one, since the light radiates
	every direction rather than down one axis or into one cone -- and nothing
	here builds that yet (P3, `shadow_cube.odin`). `create_point_light` has no
	`casts_shadow` parameter at all, the same degrade an unsupported
	combination gets elsewhere in this package rather than an error.

	**Two shadow maps, two casters, opt-in twice over.** A light needs
	`casts_shadow = true` *and* a game needs `Lighting_Settings.shadows.enabled`
	(`set_lighting`, lighting.odin) -- see `Light`'s own doc comment in
	light.odin for why marking a light alone is harmless. This mirrors how a
	material's own shading model decides whether it is lit at all: nothing here
	changes what an existing scene looks like unless it asks.

	Why two rather than one, or an unbounded list: one was where this started,
	and it broke the moment a game had two lights that each wanted a real
	shadow at once -- a flashlight and a ceiling light, say, where turning the
	flashlight on used to mean the ceiling light's own shadow vanished
	everywhere, not just outside the beam, since only the current caster ever
	got a shadow test at all. `MAX_SHADOW_CASTERS` lights can each get their
	own map and their own test; a third `casts_shadow` light beyond that
	degrades the same way a point light already does -- silently, by not being
	picked in `set_lights` (light.odin).
*/

// Two lights may each cast a real shadow at once -- see this file's own top
// comment for why two rather than one or an unbounded list.
MAX_SHADOW_CASTERS :: 2

/*
	Which shadow technique is running. One value in P0 -- `PCF`, standard
	single-map shadow mapping filtered by hardware PCF, ported unchanged from
	what this package had before this rework (see `shadow_standard.odin`).
	`lighting_plan.md` section 2 asks for percentage-closer soft shadows,
	cascaded maps for directional lights and cube maps for point lights on top
	of this one; those are P3.

	Adding one touches exactly three places: a `.hlsli` under `shaders/shadow/`
	implementing `shadow_visibility`, a value here, and one line in that
	function's own dispatch (`lighting_core.hlsli`) -- the same shape adding a
	shading model has, see `shading.odin`.
*/
Shadow_Technique :: enum {
	PCF,
}

/*
	The value `shadow_visibility` (lighting_core.hlsli) switches on, and what
	`SHADOW_TECHNIQUE_PCF` in `shadow/contract.hlsli` must equal. Odin's own
	ordinal for the enum value, the same reasoning `shading_model_index`
	(shading.odin) gives for doing the same rather than a second switch that
	would be a fourth place a new technique has to touch.
*/
@(private)
shadow_technique_index :: proc(t: Shadow_Technique) -> f32 {
	return f32(t)
}

/*
	How the shadow map is built. `resolution` is the map's own width and
	height -- square, and deliberately modest by default: this is a low-fi
	renderer already, and a blocky shadow costs far less than a crisp one for
	a difference the rest of the picture will not make obvious anyway.

	`extent` is the half-width of the orthographic frustum around wherever the
	shadow is centred (the camera -- see `begin_shadow_pass`), in world units;
	`near`/`far` its depth range along the light's own direction. Bigger
	covers more ground and shades every texel coarser, the same trade-off any
	single shadow map has.

	`bias` is the depth-compare epsilon `shadow_pcf` (shaders/shadow/pcf.hlsli)
	subtracts before comparing -- too small and a lit surface shadows itself
	(acne), too large and a real shadow visibly detaches from its occluder
	(peter-panning). Works alongside the shadow pipelines' own rasterizer-level
	bias (`create_pipeline`'s `depth_bias`/`depth_bias_slope`, set in `init`)
	rather than instead of it.

	`enabled` is the explicit switch `lighting_rework.md` section 1's second
	defect asks for: whether the shadow system runs at all is this field alone,
	set through `set_lighting`, not an emergent property of whether any light
	happened to be marked `casts_shadow` this frame. Zero casters this frame
	with shadows enabled means no shadows were cast, which used to look
	identical to shadows being off and is not the same statement.
*/
Shadow_Settings :: struct {
	enabled:    bool,
	technique:  Shadow_Technique,
	resolution: int,
	extent:     f32,
	near, far:  f32,
	bias:       f32,
}

/*
	A human-scale outdoor scene roughly the size of examples/lighting's
	campfire clearing, with shadows turned on. A much larger or smaller game
	world wants its own settings -- there is no default that fits every scale
	of scene, which is why this is a parameter and not a fixed constant, per
	CLAUDE.md.

	Hand this to `Lighting_Settings.shadows` to turn shadows on with sane
	numbers:

		mb.set_lighting({enabled = true, shadows = mb.SHADOW_DEFAULTS, ...})

	`Lighting_Settings{}`'s own zero-valued `shadows` field is not this --
	it is `enabled = false`, which is the point: shadows stay off until a
	caller opts in, the same way they always have.
*/
SHADOW_DEFAULTS :: Shadow_Settings{
	enabled = true, technique = .PCF, resolution = 1024, extent = 20, near = 1, far = 40, bias = 0.002,
}

/*
	Zero means the default, for the numbers here that have no sensible zero
	-- see `lighting_settings_normalized` (lighting.odin) for the rule, why
	it exists, and why the fixup lands at store time.

	This is what makes `shadows = {enabled = true}` a working way to turn
	shadows on with sane numbers, rather than a 0x0 shadow map inside a
	frustum of zero width and zero depth. `SHADOW_DEFAULTS` stays the more
	readable spelling of the same thing, and stays the one to copy and adjust
	when a scene wants its own scale.

	`enabled` and `technique` are untouched: false is a scene that casts no
	shadows, and `technique`'s zero is `PCF`, a real value and the only one
	P0 built.

	Every number is left alone while `enabled` is false, rather than filled
	in and ignored. A caller that turns shadows off and later back on should
	get the numbers it actually wrote back, including deliberate zeroes it
	set while they were off.

	`bias` is the one judgement call here. A zero shader-side bias is
	arguably legitimate -- the shadow pipelines carry a rasterizer-level
	bias of their own (`create_pipeline`'s `depth_bias`/`depth_bias_slope`),
	so zero here is not the same as no bias at all. It is defaulted anyway,
	because acne is an artifact `lighting_plan.md` section 2 is explicit
	about not shipping, and "I wrote zero deliberately" is far rarer than "I
	did not fill this in". P3 replaces this single number with a per-technique
	bias framework and should revisit the call then.
*/
@(private)
shadow_settings_normalized :: proc(settings: Shadow_Settings) -> Shadow_Settings {
	s := settings
	if !s.enabled do return s

	if s.resolution == 0 do s.resolution = SHADOW_DEFAULTS.resolution
	if s.extent     == 0 do s.extent     = SHADOW_DEFAULTS.extent
	if s.near       == 0 do s.near       = SHADOW_DEFAULTS.near
	if s.far        == 0 do s.far        = SHADOW_DEFAULTS.far
	if s.bias       == 0 do s.bias       = SHADOW_DEFAULTS.bias

	return s
}

/*
	Everything the shadow pass owns at runtime, as last resolved by
	`set_lighting` -- grouped the way `Lighting` (render.odin) groups
	everything lighting owns, rather than as loose fields on `Renderer`.

	`textures[n]` is never nil once a device exists: `init` creates a 1x1
	placeholder for each slot immediately, so the mesh fragment shader -- which
	declares both slots unconditionally, for every game -- always has
	something valid bound, whether or not that game ever turns shadows on or
	ever has more than one light marked `casts_shadow`. See `shadow_standard.odin`.

	Two of everything shadow-specific rather than one: `MAX_SHADOW_CASTERS`
	lights can each cast a real shadow at once, each into its own map. One
	`sampler`/`format`/`resolution` still serve both -- they are the shadow
	system's own settings, not a per-light choice.
*/
Shadow_State :: struct {
	settings: Shadow_Settings,

	sampler:    ^sdl.GPUSampler,
	format:     sdl.GPUTextureFormat,
	resolution: i32,

	textures:         [MAX_SHADOW_CASTERS]^sdl.GPUTexture,
	view_projections: [MAX_SHADOW_CASTERS]matrix[4, 4]f32,
	caster_indices:   [MAX_SHADOW_CASTERS]int, // which uploaded light each casts, or -1 -- see set_lights

	// Which of the two the current shadow pass is filling -- read by
	// draw_model_immediate to pick the matching view_projections entry.
	active_slot: int,

	// Whether begin_shadow_pass has already logged its "nothing to render"
	// warning for the current stretch of no-caster/disabled frames, so a game
	// that leaves the call in its loop with shadows off gets one line instead
	// of one every frame. Only slot 0 ever warns -- an empty slot 1 is the
	// ordinary shape of a game with one shadow-casting light, not a
	// misconfiguration.
	warned: bool,
}
