package matchbox

/*
	Lighting -- scene state
	------------------------
	Whether the lighting model runs at all, and everything else that is a
	property of the scene rather than of one light or one material: which
	render pipeline is driving it, the shadow system's own settings, ambient,
	fog.

	**This is the fix for both defects `lighting_rework.md` section 1 opens
	with.** Before this file existed, "is lighting on" was read off the count
	of lights `set_lights` had last been given -- a scene whose only light was
	a player-toggled flashlight flipped between the real shading and a
	hard-coded fallback direction as the player pressed a key, and the shadow
	system degraded the same way, silently, off `enable_shadows`'s own
	unrelated on/off switch plus whether anything happened to be marked
	`casts_shadow` *this frame*. `enabled` below and `Shadow_Settings.enabled`
	(`shadow.odin`) are that state made explicit: a scene says whether it is
	lit and whether it casts shadows, and a material with nothing to say about
	either of those states says so itself with `Shading_Model.UNLIT`
	(`material.odin`) rather than the two ever being confused for each other
	again.
*/

import sdl "vendor:sdl3"

/*
	Which render pipeline is driving the 3D pass. One value in P0 -- `FORWARD`,
	which is what this package has always done and the only one built or
	tested. `lighting_plan.md` section 3 asks for deferred and clustered
	forward+ on top of this; `lighting_rework.md` section 3.6's own build
	order is explicit that forward is finished and validated alone before
	either of those begins, which is a later phase's work, not this one's.

	Declared now, with the one value P0 actually runs, because `Lighting_Settings`
	names its field either way -- see that struct's own doc comment. Nothing
	in `render3d.odin` branches on this yet; there is exactly one pipeline to
	branch to.
*/
Render_Pipeline_Kind :: enum {
	FORWARD,
}

// The light that reaches every surface regardless of where it faces or what
// casts a shadow toward it. Divided by ten inside brdf/blinn_phong.hlsli,
// which is PsxGame's own scaling and is kept so that a value carried over
// from there means the same thing. `Shading_Model.UNLIT` never reads this --
// an unlit material ignores every piece of scene lighting, ambient included.
Ambient :: struct {
	color: [4]f32,
}

/*
	Distance fade: nothing changes nearer than `start`, everything is `color`
	by `end`. Its own `enabled` rather than a magic range, so "fog is off" is
	a statement rather than a range nothing will ever reach.

	Fog is what makes a dark scene readable rather than a black one with
	objects popping out of it, and it is most of the mood in PsxGame -- there
	it is a dark blue from 3 units to 12.

	**`color` is a linear value now, not a display one.** Before P1, this was
	mixed into `shade_surface`'s output *after* that function's own gamma
	encode -- see `shade_surface`'s doc comment in `lighting_core.hlsli` for
	why that was the one place gamma ran per shading model rather than once
	for the whole pass. That made `color` mean exactly what a game picked: it
	was the last thing written before the pixel left the shader. P1 deletes
	that per-model encode entirely -- the whole 3D pass writes linear light to
	an HDR target now, and gamma happens once, in the tonemap resolve
	(`tonemap.odin`), after fog is mixed in. So `color` is mixed alongside
	every light's own linear colour and then run through whatever curve
	`Lighting_Settings.tonemap` is, the same as everything else in the scene --
	it is no longer the exact pixel value a game will see, the same way a
	light's own `color` never was. A game carrying a fog colour over from
	before this phase should expect it to look different, not just gamma-
	shifted: see `Lighting_Settings.tonemap`'s own doc comment for why a
	tonemap curve changes more than a straight gamma decode would.
*/
Fog :: struct {
	enabled:    bool,
	color:      [4]f32,
	start, end: f32,
}

/*
	Which curve the tonemap resolve (`tonemap.odin`) runs after exposure and
	before the final gamma encode, turning the 3D pass's unbounded linear
	light into the [0, 1] range a display expects. `NONE` is not "no curve
	ran" -- it still clamps to [0, 1] and still gets the same encode every
	other value does, which is what makes it useful as a baseline: comparing
	`NONE` against `REINHARD` isolates exactly what the curve itself changed,
	because the encode on both sides is identical. See `tonemap.odin`'s own
	top comment for the arithmetic each one runs, mirrored statement for
	statement between there (tested, `tonemap_test.odin`) and
	`shaders/tonemap.frag.hlsl` (not directly testable -- there is no GPU
	capture tooling here, so the shader is trusted to match its own CPU-side
	mirror rather than verified rendering).

	`REINHARD` is the simplest compression curve that exists (`c / (1 + c)`)
	and the cheapest way to stop a bright light from clipping to a flat white
	disc. `ACES` is Narkowicz's fitted approximation to the ACES filmic
	reference curve -- the three-line version nearly every engine that calls
	its tonemap "ACES" actually means, not the real RRT+ODT, which is a 3D
	LUT. `AGX` is a minimal approximation of Troy Sobotka's AgX (the inset
	matrix, the log2 encode, the polynomial contrast fit) -- see
	`tonemap_agx`'s own doc comment in `tonemap.odin` for what is deliberately
	left out and why.
*/
Tonemap :: enum {
	NONE,
	REINHARD,
	ACES,
	AGX,
}

/*
	One struct, set explicitly, replacing the "count of lights implies the
	mode" arrangement this file's own top comment describes.

		mb.set_lighting({
			enabled  = true,
			ambient  = {color = {0.35, 0.35, 0.55, 1}},
			fog      = {enabled = true, color = FOG_COLOR, start = 3, end = 12},
			shadows  = mb.SHADOW_DEFAULTS,
			exposure = 1,
		})

	Every call replaces the whole struct rather than patching one field, the
	same as `set_lights` replaces the whole light list -- a game that wants to
	flip one thing keeps its own `Lighting_Settings` value and re-submits it
	with that field changed, which is one assignment and one call.
*/
Lighting_Settings :: struct {
	enabled:  bool,                 // does the lighting model run at all
	pipeline: Render_Pipeline_Kind, // FORWARD in P0 -- see that enum's own doc comment
	shadows:  Shadow_Settings,      // technique + its own parameters
	ambient:  Ambient,
	fog:      Fog,

	/*
		Multiplies every linear colour the 3D pass produces before the
		tonemap curve (`tonemap` below) runs -- see `resolve_tonemap`
		(tonemap.odin). 1 leaves the numbers alone; above 1 brightens a scene
		that reads too dark under whichever curve is running, below 1 darkens
		one that clips too much of its own highlights.

		**Has no sensible zero, unlike every other field here**, so zero is
		read as "not set" and becomes 1. `Ambient{}` is legitimately no
		ambient light and `Fog{}` is legitimately no fog; a zero exposure is
		nothing but a black screen, and is indistinguishable from a field
		nobody filled in until the picture is already up. `set_lighting`
		normalizes it on the way in -- see `lighting_settings_normalized` for
		the rule this is one instance of, and for why the fixup happens at
		store time rather than at use time.

		So a partial literal that never mentions exposure --
		`{enabled = true, ambient = {...}}`, the shape every example used
		before this field existed -- keeps working, and keeps working the
		same way when a later phase adds another field beside this one.
	*/
	exposure: f32,
	tonemap:  Tonemap,
}

/*
	A lit scene with shadows and fog both off, full exposure and no tonemap
	curve -- the ordinary starting point. `BUTTON_STYLE` (ui.odin) is the
	precedent CLAUDE.md names for a defaulted struct constant standing in for
	a package-level variable.

	`tonemap = .NONE` rather than a curve chosen to look nicer is deliberate:
	`lighting_rework.md` section 7.4 already released the old picture, so
	there is no look here to preserve, but P1's own job is the resolve
	machinery, not picking a house curve -- a curve is one field on this
	struct exactly so a game (or a later phase) can choose one without this
	default having to be relitigated.
*/
LIGHTING_DEFAULTS :: Lighting_Settings{enabled = true, pipeline = .FORWARD, exposure = 1, tonemap = .NONE}

/*
	Applies `settings` to the scene: whether lighting runs, whether shadows do
	and with what parameters, ambient, fog. Call it once at startup and again
	whenever any of it changes -- unlike `set_lights`, there is no reason to
	call this every frame, since none of what it holds is expected to move
	from one frame to the next the way a light's position might.

	Turning shadows on for the first time (or at a new resolution) builds real
	shadow maps here, replacing whatever was bound before -- the 1x1
	placeholders `init` made, or an earlier call's own maps at a different
	size. See `apply_shadow_settings` (shadow_standard.odin) for exactly when
	that rebuild happens and when it does not.

	A field left at zero that has no sensible zero gets its default here
	rather than being taken literally -- see `lighting_settings_normalized`
	below for the rule and which fields it covers. What is stored is the
	normalized value, so what a later read reports is what actually ran.
*/
set_lighting :: proc(settings: Lighting_Settings = LIGHTING_DEFAULTS) {
	normalized := lighting_settings_normalized(settings)

	mbi.renderer.lighting.settings = normalized
	apply_shadow_settings(normalized.shadows)
}

/*
	Zero means the default -- the rule, stated once here and applied by
	`shadow_settings_normalized` (shadow.odin) and `material_normalized`
	(material.odin) as well.

	**The problem it solves.** These structs are built as partial composite
	literals -- `{enabled = true, ambient = {...}}` -- naming only the fields
	a caller cares about, which is the shape every example in this repo uses
	and the shape CLAUDE.md's "configuration rides in as a defaulted struct"
	encourages. Odin fills the rest with zeroes. So every field added to one
	of these structs in a later phase silently changes what an existing
	literal means, and a field whose zero is not a sensible value turns every
	such literal into a broken scene with nothing to point at. `exposure`
	arrived that way in P1 and rendered nine examples solid black.

	**The rule.** Where zero is not a value anybody could mean, it is read as
	"I did not set this" and replaced with the default. Where zero *is* a
	legitimate value, it is taken literally and stays that way -- so the rule
	is a per-field judgement, not a blanket sweep, and each exception is named
	at the field it applies to.

	`Body.tint` (types.odin) is the precedent and the reasoning: an all-zero
	tint means "as it was painted" rather than "transparent black", because a
	struct that has not been filled in has to draw the picture and not a hole.
	It also shows the test a sentinel has to pass -- it must not collide with
	a value someone might legitimately want. Fading a sprite out is
	`{1, 1, 1, a}`, never all-zero, so the two cannot be confused. Every
	default below passes the same test.

	**Normalized on the way in, not on the way out.** What gets stored is the
	normalized struct, so a field read back later is the one that actually
	ran. The alternative -- resolving zeroes at the point of use and leaving
	the stored copy alone -- would mean the settings a game can inspect are
	not the settings running, which is exactly the emergent-state problem this
	file's own top comment exists to remove.

	Covered here: `exposure` alone. Every other field of `Lighting_Settings`
	has a legitimate zero -- `enabled = false` is a scene that is not lit,
	`Ambient{}` is no ambient light, `Fog{}` is no fog, and `pipeline` and
	`tonemap` both have a real first enum value (`FORWARD`, `NONE`).
*/
@(private)
lighting_settings_normalized :: proc(settings: Lighting_Settings) -> Lighting_Settings {
	s := settings

	// Zero multiplies the whole scene to black, which is never a scene
	// anybody asked for and is indistinguishable from a field nobody filled
	// in until the picture is already on screen.
	if s.exposure == 0 do s.exposure = LIGHTING_DEFAULTS.exposure

	s.shadows = shadow_settings_normalized(s.shadows)

	return s
}

// Whether the lighting model is currently running. `Lighting_Settings.enabled`,
// as last set by `set_lighting` -- mostly for an example that wants to say so
// on screen.
is_lighting_active :: proc() -> bool {
	return mbi.renderer.lighting.settings.enabled
}

/*
	224 bytes -- everything `shade_surface` (lighting_core.hlsli) needs about
	the scene besides the lights themselves, which are their own
	`StructuredBuffer` now and no longer part of this block at all. That is
	the whole reason this is smaller than the `Lighting_Data` it replaces:
	that struct carried `[MAX_LIGHTS]Light_Uniform` inline and was 1248 bytes
	at MAX_LIGHTS = 16; this is the same handful of scalars alone.

	Every member a float4 or a float4x4, for the packing reason this package
	repeats at every uniform block: HLSL pads a vector that would straddle a
	16-byte boundary, invisibly from the Odin side, so float4-everywhere is
	what makes the two sides agree by construction. 96 bytes before the two
	matrices, a multiple of 32, is what keeps Odin's own 32-byte alignment for
	`matrix[4,4]f32` from opening a gap `init`'s size assert would have to
	account for -- see `Lighting_Data`'s own history, now in git rather than
	in this file, for what it looks like when that assumption is wrong and
	nobody re-measured.
*/
Scene_Frag_Data :: struct #align(16) {
	ambient:   [4]f32, // rgb
	view_pos:  [4]f32, // xyz, filled in from the active camera
	fog_color: [4]f32, // rgb

	// x near, y far, z 1 when fog is enabled, w unused.
	fog_range: [4]f32,

	// x how many lights are set, y 1 when Lighting_Settings.enabled is true,
	// z the first shadow caster's uploaded light index or -1 for none, w the
	// shadow depth-compare bias.
	flags: [4]f32,

	// x the second shadow caster's uploaded light index or -1 for none -- two
	// lights may each cast a real shadow at once, see shadow.odin's
	// MAX_SHADOW_CASTERS. y which shadow technique is running -- see
	// shadow_visibility (lighting_core.hlsli) and Shadow_Technique
	// (shadow.odin). z-w unused.
	shadow_caster1: [4]f32,

	// Each caster's own view-projection, world space to its own clip space.
	// light_view_projection is unread whenever flags.z is -1;
	// light_view_projection2 whenever shadow_caster1.x is -1.
	light_view_projection:  matrix[4, 4]f32,
	light_view_projection2: matrix[4, 4]f32,
}

/*
	544 bytes -- `CASCADED`'s own per-cascade data, pushed alongside `Scene`
	rather than folded into it: `Scene_Frag_Data` is 224 bytes and shared by
	every technique, and most of them (`PCF`, `PCSS`, `CUBE`) never read a
	single byte of this. Splitting it out means a scene running `PCF` still
	pushes the same 224 bytes it always has, not 768.

	`view_projection` is `[MAX_SHADOW_CASTERS][MAX_CASCADES]matrix[4,4]f32`,
	caster-major and flattened -- HLSL's own array-of-matrices inside a cbuffer
	reads the same flattening, see `shaders/lighting_core.hlsli`'s own comment
	on `Cascade_Data`. Declared first, at offset 0, so its own 32-byte
	alignment (the same requirement `Scene_Frag_Data`'s own two matrices
	already have to satisfy, see that struct's doc comment) opens no gap
	`init`'s size assert would otherwise have to account for -- `splits` and
	`count` come after it rather than before for exactly that reason, not
	because of any relationship between the three.
*/
Cascade_Frag_Data :: struct #align(16) {
	view_projection: [MAX_SHADOW_CASTERS * MAX_CASCADES]matrix[4, 4]f32,

	// View-space depth of each cascade's far edge, shared by both caster
	// slots since both are directional lights sharing the one camera
	// frustum. Unused entries (past `count`) are left at whatever
	// shadow_cascaded.odin last computed and are never read past `count`.
	splits: [MAX_CASCADES]f32,

	// x how many cascades are actually configured (<= MAX_CASCADES), y-w unused.
	count: [4]f32,
}

/*
	400 bytes -- `CUBE`'s own per-face data, split out from `Scene` for the
	same reason `Cascade_Frag_Data` is: most techniques never read it.

	`view_projection` is the one caster's own six faces, in the same ±X ±Y ±Z
	order `shadow_cube.odin` builds and renders them in -- `shadow_visibility_
	cube` (shaders/shadow/cube.hlsli) has to pick the same face index this
	package picked when it rendered into it, or it will sample the wrong
	depth entirely rather than merely the wrong bias.
*/
Cube_Frag_Data :: struct #align(16) {
	view_projection: [6]matrix[4, 4]f32,

	// x the uploaded point light index this caster is, or -1 -- y-w unused.
	caster: [4]f32,
}

/*
	Hands the scene block to the GPU, with the camera filled in. Called by
	`begin_drawing_3d` rather than by `set_lighting`/`set_lights`, for two
	reasons: the view position is the pass's business and not the game's, and
	a uniform push needs a command buffer, which only exists inside a frame. A
	game may therefore set lights or lighting settings whenever it likes,
	including before `begin_drawing`.

	Fragment slot 1 is `Scene`, slot 2 `Cascade_Data`, slot 3 `Cube_Data`.
	Slot 0 is the per-part material (material.odin). The last two are pushed
	on every draw regardless of `settings.technique`, the same "always
	something valid bound, whether or not this game uses it" shape the shadow
	map placeholders already have -- see `Shadow_State`'s own doc comment.
*/
@(private)
push_lighting :: proc(camera: Camera3D) {
	r  := &mbi.renderer
	l  := &r.lighting
	sh := &l.shadow

	data := Scene_Frag_Data{
		ambient   = l.settings.ambient.color,
		view_pos  = {camera.position.x, camera.position.y, camera.position.z, 0},
		fog_color = l.settings.fog.color,
		fog_range = {l.settings.fog.start, max(l.settings.fog.end, l.settings.fog.start + 0.001), 1 if l.settings.fog.enabled else 0, 0},

		/*
			-1 in both slots whenever shadows are not enabled, even if lights
			are marked `casts_shadow` and `caster_indices` names them -- the
			shadow maps are 1x1 placeholders, never rendered into, until
			`set_lighting` builds real ones, and the shader must never be told
			to trust them.

			`flags.w`, the old single depth bias, is retired to a new job --
			see Light_Uniform's own doc comment (types.odin) for where a
			light's resolved bias moved to instead. In its place: PCSS's own
			`light_size` (world units), pre-converted here into the ortho
			shadow map's UV units, since `shaders/shadow/pcss.hlsli` has no
			other way to learn `extent` -- see that file's own top comment.
			The conversion is exact only for PCF/PCSS's own single-extent
			map; harmless when a different technique is running, since
			nothing but `shadow_visibility_pcss` ever reads it.
		*/
		flags = {
			f32(len(l.light_data)),
			1 if l.settings.enabled else 0,
			f32(sh.caster_indices[0]) if sh.settings.enabled else -1,
			pcss_uv_radius(l.settings.shadows.light_size, l.settings.shadows.extent),
		},
		shadow_caster1 = {
			f32(sh.caster_indices[1]) if sh.settings.enabled else -1,
			shadow_technique_index(sh.settings.technique),
			0, 0,
		},

		light_view_projection  = sh.view_projections[0],
		light_view_projection2 = sh.view_projections[1],
	}

	sdl.PushGPUFragmentUniformData(r.cmd, 1, &data, size_of(data))

	cascade_data: Cascade_Frag_Data
	for caster in 0 ..< MAX_SHADOW_CASTERS {
		for cascade in 0 ..< MAX_CASCADES {
			cascade_data.view_projection[caster * MAX_CASCADES + cascade] = sh.cascade_view_projections[caster][cascade]
		}
	}
	cascade_data.splits = sh.cascade_splits
	cascade_data.count  = {f32(clamp(sh.settings.cascade_count, 1, MAX_CASCADES)), 0, 0, 0}
	sdl.PushGPUFragmentUniformData(r.cmd, 2, &cascade_data, size_of(cascade_data))

	cube_data := Cube_Frag_Data{
		view_projection = sh.cube_view_projections[0],
		caster          = {f32(sh.cube_caster_index[0]) if sh.settings.enabled else -1, 0, 0, 0},
	}
	sdl.PushGPUFragmentUniformData(r.cmd, 3, &cube_data, size_of(cube_data))
}
