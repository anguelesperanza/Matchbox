package matchbox

import sdl "vendor:sdl3"

/*
	Shadows -- the contract
	------------------------
	The technique-agnostic shapes: what a shadow technique is chosen from, and
	the numbers every technique needs regardless of which one is running. The
	pass orchestration for the plain single-map technique is in
	`shadow_standard.odin` (PCF and PCSS both use it -- see that file's own
	top comment for why); `shadow_cascaded.odin` and `shadow_cube.odin` are
	P3's other two. The shader half of each is its own `.hlsli` under
	`shaders/shadow/`, behind `shaders/shadow/contract.hlsli`.

	**Two lights, two casters, opt-in twice over.** A light needs
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
	degrades the same way an unsupported combination already does elsewhere in
	this package.

	**Point lights are a separate slot, not a third entry in this array.**
	`MAX_SHADOW_CASTERS` and `caster_indices` below are for directional and
	spot casters only -- a point light radiates in every direction and needs
	six views rather than one, so it has never fit the same shape (see
	`shadow_cube.odin`'s own top comment). `set_lights` (light.odin) routes a
	`casts_shadow` point light into `cube_caster_index` instead, by kind, not
	by arrival order.
*/

// Two lights may each cast a real directional/spot shadow at once -- see this
// file's own top comment for why two rather than one or an unbounded list.
MAX_SHADOW_CASTERS :: 2

// One point light may cast a real cube shadow at once. Six faces per caster
// already multiplies the resource cost of a single map by six (six render
// passes, six sampled textures -- see `shadow_cube.odin`'s own top comment for
// why this could not simply reuse `MAX_SHADOW_CASTERS`'s shape); a second
// simultaneous point-light caster would multiply the whole mesh fragment
// shader's sampler count again for a case no example in this package has ever
// asked for. Revisit if one does.
MAX_POINT_SHADOW_CASTERS :: 1

// The most cascades a directional light's shadow may split into -- an array
// bound, the one case CLAUDE.md's "no loose constants" carves out. Four is the
// number most engines settle on: enough that the nearest cascade (where acne
// and aliasing are most visible, because the camera is closest to it) gets a
// noticeably tighter texel size than a single map covering the same far
// plane, without paying for a fifth map, matrix and bias resolve every light,
// every frame, every technique switch has to carry even when `cascade_count`
// asks for fewer.
MAX_CASCADES :: 4

/*
	Which shadow technique a directional or spot caster runs.

	`PCF` is standard single-map shadow mapping filtered by hardware PCF,
	ported unchanged from what this package had before this rework (see
	`shadow_standard.odin`). `PCSS` (percentage-closer soft shadows) reuses
	that exact same map and pass -- a blocker search and a variable-width
	filter are a shader-side difference only, see `shaders/shadow/pcss.hlsli`'s
	own top comment for why its CPU-side footprint is zero. `CASCADED` splits
	a directional caster's single map into `Shadow_Settings.cascade_count`
	maps, each covering a slice of the camera's own frustum
	(`shadow_cascaded.odin`).

	**This is a scene-wide choice, not a per-light one**, the same way
	`Shading_Model` is per-material but `Lighting_Settings.pipeline` is
	per-scene: a game cannot run `CASCADED` for one directional caster and
	plain `PCF` for the other `MAX_SHADOW_CASTERS` slot's spot light today.

	**Cube shadow maps are not a value in this enum.** A point light was never
	eligible for `PCF`/`PCSS`/`CASCADED` in the first place -- it has no
	single view to build one of these three's kind of map from at all (see
	`shadow_cube.odin`'s own top comment) -- so `CUBE` is not a competing
	choice this field selects between, it is a second, independent mechanism
	that runs whenever a point light is marked `casts_shadow`, *regardless* of
	whichever of the three above is running for the scene's directional/spot
	casters. This was the plan's own first framing (one technique enum
	covering all four), tried and rejected while wiring up
	`shadow_visibility`'s dispatch: making `CUBE` a fourth value here would
	have meant a scene could never run cascaded shadows for its sun *and* a
	real shadow for a torch at the same time, purely because both would be
	fighting over one scene-wide switch that has nothing to do with what a
	point light actually needs. Decoupling it costs nothing the mechanical
	contract cares about -- `shadow_visibility` (lighting_core.hlsli) still
	dispatches in one function, `shadow_cube.odin` still owns its own pass
	setup end to end -- and it is a real usability gain over the literal
	four-values-in-one-enum reading, so it is the shape this phase ships.

	Adding a *directional/spot* technique still touches exactly three places:
	a `.hlsli` under `shaders/shadow/` implementing `shadow_visibility_<name>`,
	a value here, and one line in that function's own dispatch
	(`shadow_visibility`, `lighting_core.hlsli`) -- the same shape adding a
	shading model has, see `shading.odin` -- plus whatever CPU-side pass setup
	its own `shadow_*.odin` file needs, which is nothing at all for `PCSS` and
	real pass orchestration for `CASCADED`.
*/
Shadow_Technique :: enum {
	PCF,
	PCSS,
	CASCADED,
}

/*
	The value `shadow_visibility` (lighting_core.hlsli) switches on, and what
	`SHADOW_TECHNIQUE_*` in `shadow/contract.hlsli` must equal. Odin's own
	ordinal for the enum value, the same reasoning `shading_model_index`
	(shading.odin) gives for doing the same rather than a second switch that
	would be a fourth place a new technique has to touch.
*/
@(private)
shadow_technique_index :: proc(t: Shadow_Technique) -> f32 {
	return f32(t)
}

/*
	Which of the three pass shapes currently has a shadow pass open --
	`draw_model_immediate` (render3d.odin) reads this to know which of
	`Shadow_State`'s three view-projection arrays to index, since `PCF`/
	`PCSS` share one two-slot shape, `CASCADED` a
	`[caster][cascade]` one, and `CUBE` a `[caster][face]` one. Not the same
	axis as `Shadow_Technique`: this says which *pass* is open right now
	(set by whichever `begin_*_shadow_pass` most recently succeeded), that
	says which technique the *scene* is configured to run.
*/
@(private)
Shadow_Pass_Kind :: enum {
	STANDARD, // PCF / PCSS -- begin_shadow_pass, shadow_standard.odin
	CASCADE,  // begin_cascade_shadow_pass, shadow_cascaded.odin
	CUBE,     // begin_point_shadow_pass, shadow_cube.odin
}

/*
	A shadow technique's own bias, factored out of `Shadow_Settings` in P3 so
	it can be both per-technique and per-light rather than the single scalar
	`bias: f32` this package started with.

	`depth` is the depth-compare epsilon every technique built on a projected
	depth-map still needs -- `shadow_sample_pcf`/`_pcss`/`_cascaded` all
	subtract it from the surface's own light-space depth before comparing,
	exactly as the old single `bias` field did. Too small and a lit surface
	shadows itself (acne, worst at a grazing angle to the light -- see
	`shadow_test.odin`'s own top comment for the trigonometry). Too large and
	a real shadow visibly detaches from its occluder (peter-panning).

	`normal_offset` is the piece that did not exist before this phase: instead
	of (or alongside) biasing the *comparison*, it moves the *sample point*
	itself off the surface, along the surface's own normal, by this many world
	units, before that point is ever projected into light space. This is what
	actually fixes acne at a grazing angle that a depth epsilon alone cannot --
	a depth bias pushes the comparison back along the *light's* axis, which at
	a shallow angle to the surface is nearly tangent to it and buys almost no
	real clearance; a normal-offset pushes the sample away from the surface
	along the *surface's* own axis instead, which is exactly the direction
	the acne-causing texel footprint error (`shadow_test.odin`) actually needs
	clearing along. The two are not redundant: `shadow_test.odin` sweeps both
	sources of error (light-space depth quantization and surface footprint)
	and neither term alone clears every configuration in that sweep.

	Both fields share the same "zero means the technique's own default"
	resolution as everything else added to this package since §3.7.1 settled
	the rule -- see `shadow_settings_normalized` for the scene-wide default and
	`light_uniform` (light.odin) for the per-light override on top of it.
*/
Shadow_Bias :: struct {
	depth:         f32,
	normal_offset: f32,
}

/*
	How the shadow map is built. `resolution` is the map's own width and
	height -- square, and deliberately modest by default: this is a low-fi
	renderer already, and a blocky shadow costs far less than a crisp one for
	a difference the rest of the picture will not make obvious anyway.

	`extent` is the half-width of the orthographic frustum around wherever the
	shadow is centred (the camera -- see `begin_shadow_pass`), in world units,
	for `PCF`/`PCSS`; `CASCADED` computes its own per-cascade extent from the
	camera's frustum instead and does not read this field (see
	`shadow_cascaded.odin`). `near`/`far` are the depth range along the
	light's own direction for every technique, `CUBE` included.

	`bias` is this scene's own default `Shadow_Bias` -- see that struct's own
	doc comment. A light with a non-zero `shadow_bias` of its own
	(`light.odin`) overrides this per-field; a light that leaves it zero reads
	this value instead. Works alongside the shadow pipelines' own
	rasterizer-level bias (`create_pipeline`'s `depth_bias`/`depth_bias_slope`,
	set in `init`) rather than instead of it.

	`light_size`, `cascade_count` and `cascade_split_lambda` are flat rather
	than nested per technique, the same shape `Material` already uses for its
	own per-shading-model parameters (`material.odin`'s own top comment) --
	a cbuffer wants a flat layout, and which of these means anything is
	documented per technique in the `.hlsli` that reads it. `light_size` is
	`PCSS`'s own -- the light's apparent width in world units, which is what
	turns its blocker search into a penumbra that widens with occluder
	distance rather than a fixed-width PCF kernel; see
	`shaders/shadow/pcss.hlsli`. `cascade_count` and `cascade_split_lambda`
	are `CASCADED`'s own -- see `shadow_cascaded.odin`.

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
	bias:       Shadow_Bias,

	light_size: f32, // PCSS only -- world units, the light's own apparent width

	cascade_count:        int, // CASCADED only -- clamped to [1, MAX_CASCADES]
	cascade_split_lambda: f32, // CASCADED only -- 0 uniform splits, 1 fully logarithmic
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

	`bias`'s two numbers are sourced from `shadow_test.odin`'s own derivation
	and sweep, not picked by eye and then tuned until a picture looked right.
	`depth = 0.0013` sits at roughly 1.3x the *minimum* depth bias that same
	file derives independently (texel footprint times the sine of the angle
	between the light and the surface, halved for the worst on-texel offset,
	scaled into this map's own NDC-z units) for the most grazing angle and
	the coarsest resolution the sweep checks -- comfortable margin over a
	real minimum, not a number chosen to make a test pass. `normal_offset =
	0.05` is a flat safety margin on top for curved or faceted geometry the
	flat-plane derivation cannot see (its own footprint analysis assumes a
	perfectly flat receiver) -- see that file's own top comment for exactly
	what is and is not proven about each number. A scene with a much larger
	`extent` or much smaller `resolution` than these defaults has a coarser
	texel and wants a bigger `depth`, the same trade `resolution` and
	`extent` already have with each other -- and, per `shadow_test.odin`'s
	own finding, a scene at a *finer* resolution than these defaults sees the
	same absolute peter-panning distance turn into more shadow-map texels of
	it, purely because the texels themselves are smaller; that is a property
	of any fixed-in-world-units bias, not a bug in this default's own choice
	of resolution to be tuned for.
*/
SHADOW_DEFAULTS :: Shadow_Settings{
	enabled = true, technique = .PCF, resolution = 1024, extent = 20, near = 1, far = 40,
	bias = Shadow_Bias{depth = 0.0013, normal_offset = 0.05},
	light_size = 0.5,
	cascade_count = 4, cascade_split_lambda = 0.5,
}

/*
	`Shadow_Settings.light_size` (world units) converted into the ortho
	shadow map's own UV units -- `shaders/shadow/pcss.hlsli` has no other way
	to learn `extent` (see that file's own top comment), so `push_lighting`
	(lighting.odin) does this division once, here, rather than pushing
	`extent` itself just for this one technique to divide by every fragment.

	A free-standing function rather than inlined into `push_lighting`, so
	`shadow_test.odin` can check the conversion against a hand-worked value
	without needing a renderer.
*/
pcss_uv_radius :: proc(light_size, extent: f32) -> f32 {
	return light_size / (2 * max(extent, 0.0001))
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
	shadows, and `technique`'s zero is `PCF`, a real value and the first one
	this package built.

	Every number is left alone while `enabled` is false, rather than filled
	in and ignored. A caller that turns shadows off and later back on should
	get the numbers it actually wrote back, including deliberate zeroes it
	set while they were off.

	`bias`'s two fields are each their own judgement call, made independently
	per CLAUDE.md's "per-field judgement, not a sweep" -- a zero shader-side
	depth bias or normal-offset is arguably legitimate on its own (the shadow
	pipelines carry a rasterizer-level bias of their own, so zero here is not
	the same as no bias at all), but both are defaulted anyway, for the same
	reason the single scalar `bias` always was: acne is an artifact
	`lighting_plan.md` section 2 is explicit about not shipping, and "I wrote
	zero deliberately" is far rarer than "I did not fill this in" for either
	number.

	`light_size` (PCSS) and `cascade_split_lambda` (CASCADED) join them for
	the same reason `bands` joined `material_normalized`'s own defaults
	(material.odin): a zero light size collapses PCSS's penumbra to nothing,
	which is indistinguishable from ordinary PCF and not a real choice anyone
	visibly asked for by leaving a field at zero, and a zero split lambda is a
	real, if extreme, choice (perfectly uniform cascade splits) that this
	package leaves alone rather than folds into the default -- see
	`shadow_cascaded.odin` for why uniform splits are a real answer and not an
	oversight. `cascade_count` is defaulted for the same reason `resolution`
	always was: zero cascades is zero shadow maps for a light the scene has
	just been told casts one.
*/
@(private)
shadow_settings_normalized :: proc(settings: Shadow_Settings) -> Shadow_Settings {
	s := settings
	if !s.enabled do return s

	if s.resolution == 0 do s.resolution = SHADOW_DEFAULTS.resolution
	if s.extent     == 0 do s.extent     = SHADOW_DEFAULTS.extent
	if s.near       == 0 do s.near       = SHADOW_DEFAULTS.near
	if s.far        == 0 do s.far        = SHADOW_DEFAULTS.far

	if s.bias.depth         == 0 do s.bias.depth         = SHADOW_DEFAULTS.bias.depth
	if s.bias.normal_offset == 0 do s.bias.normal_offset = SHADOW_DEFAULTS.bias.normal_offset

	if s.light_size == 0 do s.light_size = SHADOW_DEFAULTS.light_size

	if s.cascade_count == 0 do s.cascade_count = SHADOW_DEFAULTS.cascade_count
	s.cascade_count = clamp(s.cascade_count, 1, MAX_CASCADES)

	return s
}

/*
	Everything the shadow pass owns at runtime, as last resolved by
	`set_lighting` -- grouped the way `Lighting` (render.odin) groups
	everything lighting owns, rather than as loose fields on `Renderer`.

	`textures[n]` is never nil once a device exists: `init` creates a 1x1
	placeholder for each slot immediately, so the mesh fragment shader -- which
	declares every slot below unconditionally, for every game, regardless of
	which technique is actually running -- always has something valid bound.
	See `shadow_standard.odin`, `shadow_cascaded.odin`, `shadow_cube.odin`.

	Three independent groups of resources rather than one: `textures`/
	`view_projections`/`caster_indices` are `PCF`/`PCSS`'s own two-slot shape,
	unchanged from before this phase; `cascade_*` is `CASCADED`'s, sized for
	up to `MAX_SHADOW_CASTERS` directional casters each split into up to
	`MAX_CASCADES` maps; `cube_*` is `CUBE`'s, sized for
	`MAX_POINT_SHADOW_CASTERS`. All three exist on every `Shadow_State`
	regardless of `settings.technique` -- see `Shadow_Technique`'s own doc
	comment on why the mesh fragment shader cannot pick and choose which
	sampler slots to declare.
*/
Shadow_State :: struct {
	settings: Shadow_Settings,

	sampler: ^sdl.GPUSampler,
	format:  sdl.GPUTextureFormat,

	// Each technique group tracks the resolution it was last actually built
	// at, separately -- not one shared field. `init` gives every group a 1x1
	// placeholder up front (see this struct's own doc comment), so
	// `textures[n] != nil` is true from the very start and cannot by itself
	// tell a real map from a placeholder the way "built at this resolution"
	// can.
	resolution:          i32, // PCF / PCSS
	cascade_resolution:  i32, // CASCADED
	cube_resolution:     i32, // CUBE

	// PCF / PCSS.
	textures:         [MAX_SHADOW_CASTERS]^sdl.GPUTexture,
	view_projections: [MAX_SHADOW_CASTERS]matrix[4, 4]f32,
	caster_indices:   [MAX_SHADOW_CASTERS]int, // which uploaded light each casts, or -1 -- see set_lights

	// CASCADED -- see shadow_cascaded.odin.
	cascade_textures:         [MAX_SHADOW_CASTERS][MAX_CASCADES]^sdl.GPUTexture,
	cascade_view_projections: [MAX_SHADOW_CASTERS][MAX_CASCADES]matrix[4, 4]f32,
	cascade_splits:           [MAX_CASCADES]f32, // view-space depth of each cascade's far edge, shared by both caster slots

	// CUBE -- see shadow_cube.odin.
	cube_textures:         [MAX_POINT_SHADOW_CASTERS][6]^sdl.GPUTexture,
	cube_view_projections: [MAX_POINT_SHADOW_CASTERS][6]matrix[4, 4]f32,
	cube_caster_index:     [MAX_POINT_SHADOW_CASTERS]int, // which uploaded point light casts, or -1

	// Which slot/cascade/face the current shadow pass is filling, and which
	// technique's own pass shape opened it -- read by draw_model_immediate to
	// pick the matching view-projection out of the right array above.
	active_slot:    int,
	active_cascade: int,
	active_face:    int,
	active_kind:    Shadow_Pass_Kind,

	// Whether begin_shadow_pass has already logged its "nothing to render"
	// warning for the current stretch of no-caster/disabled frames, so a game
	// that leaves the call in its loop with shadows off gets one line instead
	// of one every frame. Only slot 0 ever warns -- an empty slot 1 is the
	// ordinary shape of a game with one shadow-casting light, not a
	// misconfiguration.
	warned: bool,
}
