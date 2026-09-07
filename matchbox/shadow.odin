package matchbox

/*
	Shadows
	-------
	Whether an occluder actually blocks a light, for up to two lights a game
	names as casters.

	**Directional and spot, not point.** A point light's shadow needs a
	cubemap -- six depth renders instead of one, since the light radiates
	every direction rather than down one axis or into one cone -- and nothing
	here builds that. `create_point_light` has no `casts_shadow` parameter at
	all, the same degrade an unsupported combination gets elsewhere in this
	package rather than an error.

	**Two shadow maps, two casters, opt-in twice over.** A light needs
	`casts_shadow = true` *and* a game needs to call `enable_shadows` -- see
	`Light`'s own doc comment in light.odin for why marking a light alone is
	harmless. This mirrors how lighting itself only replaces the fixed
	fallback shading once a light is actually set, and how fog is its own
	`set_fog`/`disable_fog` switch: nothing here changes what an existing
	game looks like unless it asks.

	Why two rather than one, or an unbounded list: one was where this
	started, and it broke the moment a game had two lights that each wanted
	a real shadow at once -- a flashlight and a ceiling light, say, where
	turning the flashlight on used to mean the ceiling light's own shadow
	vanished everywhere, not just outside the beam, since only the current
	caster ever got a shadow test at all. `MAX_SHADOW_CASTERS` lights can
	each get their own map and their own test; a third `casts_shadow` light
	beyond that degrades the same way a point light already does -- silently,
	by not being picked in `recompute_shadow_casters` (light.odin).

	**Explicit, not folded into `begin_drawing_3d`.** A game calls
	`begin_shadow_pass`/`end_shadow_pass` itself, drawing whatever should
	cast a shadow in between, before its normal `begin_drawing_3d` block --
	the same shape `begin_drawing_target`/`draw_post` (render_target.odin)
	already externalizes a render-to-texture pass to the caller rather than
	hiding it inside another procedure. `begin_shadow_pass` takes which of
	the two maps to fill; a game with only one shadow-casting light never
	passes it and gets exactly today's single-caster shape.
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

// Two lights may each cast a real shadow at once -- see this file's own top
// comment for why two rather than one or an unbounded list.
MAX_SHADOW_CASTERS :: 2

/*
	How the shadow map is built. `resolution` is the map's own width and
	height -- square, and deliberately modest by default: this is a low-fi
	renderer already, and a blocky shadow costs far less than a crisp one
	for a difference the rest of the picture will not make obvious anyway.

	`extent` is the half-width of the orthographic frustum around wherever
	the shadow is centred (the camera -- see `begin_shadow_pass`), in world
	units; `near`/`far` its depth range along the light's own direction.
	Bigger covers more ground and shades every texel coarser, the same
	trade-off any single shadow map has.

	`bias` is the depth-compare epsilon `shadow_factor` (lighting.hlsli)
	subtracts before comparing -- too small and a lit surface shadows
	itself (acne), too large and a real shadow visibly detaches from its
	occluder (peter-panning). Works alongside the shadow pipelines' own
	rasterizer-level bias (`create_pipeline`'s `depth_bias`/
	`depth_bias_slope`, set in `init`) rather than instead of it.
*/
Shadow_Settings :: struct {
	resolution: int,
	extent:     f32,
	near, far:  f32,
	bias:       f32,
}

// A human-scale outdoor scene roughly the size of examples/lighting's
// campfire clearing. A much larger or smaller game world wants its own
// settings -- there is no default that fits every scale of scene, which is
// why this is a parameter and not a fixed constant, per CLAUDE.md.
SHADOW_DEFAULTS :: Shadow_Settings{resolution = 1024, extent = 20, near = 1, far = 40, bias = 0.002}

/*
	Turns shadows on: builds `MAX_SHADOW_CASTERS` real shadow maps at
	`settings.resolution`, one per potential caster, replacing whatever
	textures were bound in their place -- the 1x1 placeholders `init` made,
	or earlier real maps from a previous call with different settings.

	Casts nothing by itself. A light also needs `casts_shadow = true` (see
	`Light`), and `begin_shadow_pass`/`end_shadow_pass` need to actually run
	each frame around whatever should cast one -- this only says the shadow
	maps should exist and be trusted once they do.
*/
enable_shadows :: proc(settings: Shadow_Settings = SHADOW_DEFAULTS) {
	r := &mbi.renderer
	if r.device == nil do return

	size := max(settings.resolution, 1)

	new_textures: [MAX_SHADOW_CASTERS]^sdl.GPUTexture
	for slot in 0 ..< MAX_SHADOW_CASTERS {
		new_textures[slot] = sdl.CreateGPUTexture(r.device, {
			type                 = .D2,
			format               = r.shadow.format,
			usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width                = u32(size),
			height               = u32(size),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})

		if new_textures[slot] == nil {
			log.errorf("could not create a shadow map: %s", sdl.GetError())
			r.shadow.enabled = false

			// Whatever this call already made before failing is released
			// rather than leaked; whatever was there before (placeholders or
			// a previous enable_shadows' real maps) is left alone, since it
			// is still what every other slot -- and a future retry -- reads.
			for made in new_textures[:slot] {
				sdl.ReleaseGPUTexture(r.device, made)
			}
			return
		}
	}

	for slot in 0 ..< MAX_SHADOW_CASTERS {
		if r.shadow.textures[slot] != nil {
			sdl.ReleaseGPUTexture(r.device, r.shadow.textures[slot])
		}
		r.shadow.textures[slot] = new_textures[slot]
	}

	r.shadow.settings   = settings
	r.shadow.resolution = i32(size)
	r.shadow.enabled    = true
}

/*
	Back to no shadow at all -- the map itself is left alone rather than
	released, so a game toggling this as a debug key does not rebuild a
	texture every press. `enable_shadows` is what actually replaces it.
*/
disable_shadows :: proc() {
	mbi.renderer.shadow.enabled = false
}

// Whether enable_shadows has been called and disable_shadows has not undone it.
is_shadows_active :: proc() -> bool {
	return mbi.renderer.shadow.enabled
}

/*
	Opens the shadow pass for `slot` (0 or 1 -- see `MAX_SHADOW_CASTERS`):
	works out that slot's own caster's view-projection, then a depth-only
	render pass against that slot's shadow map, ready for whatever
	`draw_model` calls come next to render into it as occluders rather than
	as the visible scene.

	**Returns whether it actually opened one.** `false` when there is
	nothing to render at this slot -- `enable_shadows` was never called, or
	no light is marked `casts_shadow` for this slot (`recompute_shadow_casters`,
	light.odin) -- which is an ordinary state for a game with fewer
	shadow-casting lights than `MAX_SHADOW_CASTERS`, or one that has not
	turned shadows on yet, not a mistake. `draw_model` still asserts loudly
	if asked to draw with no pass of the right kind open, so a caller that
	draws inside this block has to check the return value for exactly that
	reason:

		if mb.begin_shadow_pass() {
			mb.draw_model_at(occluder, position, scale)
			mb.end_shadow_pass()
		}

	Two lights casting at once means calling this (and its matching
	`end_shadow_pass`) once per slot:

		for slot in 0 ..< mb.MAX_SHADOW_CASTERS {
			if mb.begin_shadow_pass(slot) {
				mb.draw_model_at(occluder, position, scale)
				mb.end_shadow_pass()
			}
		}

	Logged once per change of state rather than every frame a game leaves
	shadows off -- see `r.shadow.warned` below. Only slot 0 ever logs it: an
	empty slot 1 is the ordinary shape of a game with one shadow-casting
	light, not something to warn about every frame.

	**Centred on the camera for a directional light, on the light itself for a
	spot.** A directional light has no position of its own to build a frustum
	around, and this renderer has no scene bounds to ask for one either -- so
	its frustum is faked, centred on the last camera position
	`begin_drawing_3d` was given (one frame behind whatever
	`begin_shadow_pass` runs with this frame, since it runs first by
	convention -- imperceptible at any real frame rate, and simpler than
	threading a position through an API the plan deliberately kept
	parameterless). A spotlight needs none of that: it already has a real
	position and direction, so its frustum is built from those directly, at a
	field of view matching its own cone.
*/
begin_shadow_pass :: proc(slot: int = 0) -> bool {
	r := &mbi.renderer
	if !r.frame_active do return false
	if slot < 0 || slot >= MAX_SHADOW_CASTERS do return false

	if !r.shadow.enabled || r.shadow.caster_indices[slot] < 0 {
		if slot == 0 && !r.shadow.warned {
			log.warn("begin_shadow_pass: shadows are not enabled, or no light is marked casts_shadow -- skipped")
			r.shadow.warned = true
		}
		return false
	}
	if slot == 0 do r.shadow.warned = false

	caster  := r.lighting.lights[r.shadow.caster_indices[slot]]
	is_spot := caster.target.w > 1.5

	direction: [3]f32
	eye:       [3]f32

	if is_spot {
		// target IS the raw direction for a spot, the same convention a
		// directional light's own target is -- and unlike a directional
		// light, a spotlight has a real position to shine the shadow from
		// rather than one faked from the camera.
		direction = linalg.normalize(caster.target.xyz)
		eye       = caster.position.xyz
	} else {
		direction = linalg.normalize(caster.target.xyz - caster.position.xyz)
		center    := r.camera3d.position
		eye        = center - direction * r.shadow.settings.far * 0.5
	}

	// look_at_matrix degenerates when `up` is parallel to the direction it is
	// squared against -- a light pointing straight up or down. {0,0,1} is
	// never parallel to a direction whose y is ±1, so it is the fallback
	// rather than a second special case to keep in step with the first.
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(direction, up)) > 0.99 {
		up = {0, 0, 1}
	}

	settings := r.shadow.settings
	view     := look_at_matrix(eye, eye + direction, up)

	proj: matrix[4, 4]f32
	if is_spot {
		// The outer half-angle doubled to a full field of view, clamped away
		// from perspective()'s degenerate ends -- a cone this package would
		// call a floodlight rather than a spotlight long before either bound
		// is reached. Aspect 1: the shadow map is square.
		fov := clamp(caster.cone.x * 2, 1, 170)
		proj = perspective(fov, 1, settings.near, settings.far)
	} else {
		proj = ortho(-settings.extent, settings.extent, -settings.extent, settings.extent, settings.near, settings.far)
	}

	r.shadow.view_projections[slot] = proj * view
	r.shadow.active_slot            = slot

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = r.shadow.textures[slot],
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .STORE, // read back as a texture in the very next pass
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	// No colour target at all -- create_pipeline's `color_target = false`
	// pipelines are what make a pass with zero of them valid to bind against.
	r.pass = sdl.BeginGPURenderPass(r.cmd, nil, 0, &depth)
	if r.pass == nil do return false

	bind_cache_reset()

	r.in_shadow_pass = true
	return true
}

// Closes the shadow pass. Whatever runs next -- ordinarily begin_drawing_3d
// -- opens its own pass and samples the map this one just wrote.
end_shadow_pass :: proc() {
	r := &mbi.renderer
	if !r.in_shadow_pass do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	r.in_shadow_pass = false
}
