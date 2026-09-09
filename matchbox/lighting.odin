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
*/
Fog :: struct {
	enabled:    bool,
	color:      [4]f32,
	start, end: f32,
}

/*
	One struct, set explicitly, replacing the "count of lights implies the
	mode" arrangement this file's own top comment describes.

		mb.set_lighting({
			enabled = true,
			ambient = {color = {0.35, 0.35, 0.55, 1}},
			fog     = {enabled = true, color = FOG_COLOR, start = 3, end = 12},
			shadows = mb.SHADOW_DEFAULTS,
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
}

// A lit scene with shadows and fog both off -- the ordinary starting point.
// `BUTTON_STYLE` (ui.odin) is the precedent CLAUDE.md names for a defaulted
// struct constant standing in for a package-level variable.
LIGHTING_DEFAULTS :: Lighting_Settings{enabled = true, pipeline = .FORWARD}

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
*/
set_lighting :: proc(settings: Lighting_Settings = LIGHTING_DEFAULTS) {
	mbi.renderer.lighting.settings = settings
	apply_shadow_settings(settings.shadows)
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
	Hands the scene block to the GPU, with the camera filled in. Called by
	`begin_drawing_3d` rather than by `set_lighting`/`set_lights`, for two
	reasons: the view position is the pass's business and not the game's, and
	a uniform push needs a command buffer, which only exists inside a frame. A
	game may therefore set lights or lighting settings whenever it likes,
	including before `begin_drawing`.

	Fragment slot 1. Slot 0 is the per-part material (material.odin).
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
		*/
		flags = {
			f32(len(l.light_data)),
			1 if l.settings.enabled else 0,
			f32(sh.caster_indices[0]) if sh.settings.enabled else -1,
			sh.settings.bias,
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
}
