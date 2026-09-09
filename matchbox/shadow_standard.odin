package matchbox

/*
	Shadows -- standard shadow mapping
	-----------------------------------
	Depth-from-light-view, one map per caster slot, filtered by hardware PCF
	on the sample -- see `shaders/shadow/pcf.hlsli`. This is what Matchbox had
	before this rework, moved behind `Shadow_Technique.PCF` unchanged: the
	whole point of doing that first is that it is the reference picture the
	rest of P0 is checked against, not a new technique.

	**Explicit, not folded into `begin_drawing_3d`.** A game calls
	`begin_shadow_pass`/`end_shadow_pass` itself, drawing whatever should cast
	a shadow in between, before its normal `begin_drawing_3d` block -- the
	same shape `begin_drawing_target`/`draw_post` (render_target.odin) already
	externalizes a render-to-texture pass to the caller rather than hiding it
	inside another procedure. `begin_shadow_pass` takes which of the two maps
	to fill; a game with only one shadow-casting light never passes it and
	gets exactly today's single-caster shape.
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	Brings `Shadow_State` in line with `settings`, called by `set_lighting`
	whenever the shadow half of `Lighting_Settings` changes.

	Builds `MAX_SHADOW_CASTERS` real shadow maps at `settings.resolution` only
	when turning shadows on for the first time or when the resolution itself
	changed -- an unrelated setting flipping (fog, ambient, a light moving)
	should not rebuild a texture every frame `set_lighting` happens to be
	called with the same shadow resolution. Turning shadows off leaves
	whatever maps already exist alone, the same "the map itself is left alone
	rather than released" shape the old `disable_shadows` had, so a game
	toggling this as a debug key does not rebuild a texture every press.
*/
@(private)
apply_shadow_settings :: proc(settings: Shadow_Settings) {
	r := &mbi.renderer
	s := &r.lighting.shadow

	s.settings = settings

	if !settings.enabled {
		return
	}

	size := max(settings.resolution, 1)
	if s.resolution == i32(size) && s.textures[0] != nil && s.textures[1] != nil {
		return // already built at this resolution -- nothing to do
	}

	if r.device == nil do return

	new_textures: [MAX_SHADOW_CASTERS]^sdl.GPUTexture
	for slot in 0 ..< MAX_SHADOW_CASTERS {
		new_textures[slot] = sdl.CreateGPUTexture(r.device, {
			type                 = .D2,
			format               = s.format,
			usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width                = u32(size),
			height               = u32(size),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})

		if new_textures[slot] == nil {
			log.errorf("could not create a shadow map: %s", sdl.GetError())
			s.settings.enabled = false

			// Whatever this call already made before failing is released
			// rather than leaked; whatever was there before (placeholders or
			// a previous call's real maps) is left alone, since it is still
			// what every other slot -- and a future retry -- reads.
			for made in new_textures[:slot] {
				sdl.ReleaseGPUTexture(r.device, made)
			}
			return
		}
	}

	for slot in 0 ..< MAX_SHADOW_CASTERS {
		if s.textures[slot] != nil {
			sdl.ReleaseGPUTexture(r.device, s.textures[slot])
		}
		s.textures[slot] = new_textures[slot]
	}

	s.resolution = i32(size)
}

// Whether the shadow system is currently running -- set_lighting's own
// Lighting_Settings.shadows.enabled, as last resolved.
is_shadows_active :: proc() -> bool {
	return mbi.renderer.lighting.shadow.settings.enabled
}

/*
	Opens the shadow pass for `slot` (0 or 1 -- see `MAX_SHADOW_CASTERS`):
	works out that slot's own caster's view-projection, then a depth-only
	render pass against that slot's shadow map, ready for whatever
	`draw_model` calls come next to render into it as occluders rather than as
	the visible scene.

	**Returns whether it actually opened one.** `false` when there is nothing
	to render at this slot -- shadows are not enabled, or no light is marked
	`casts_shadow` for this slot (`set_lights`, light.odin) -- which is an
	ordinary state for a game with fewer shadow-casting lights than
	`MAX_SHADOW_CASTERS`, or one that has not turned shadows on yet, not a
	mistake. `draw_model` still asserts loudly if asked to draw with no pass of
	the right kind open, so a caller that draws inside this block has to check
	the return value for exactly that reason:

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
	shadows off -- see `Shadow_State.warned`. Only slot 0 ever logs it: an
	empty slot 1 is the ordinary shape of a game with one shadow-casting
	light, not something to warn about every frame.

	**Centred on the camera for a directional light, on the light itself for a
	spot.** A directional light has no position of its own to build a frustum
	around, and this renderer has no scene bounds to ask for one either -- so
	its frustum is faked, centred on the last camera position
	`begin_drawing_3d` was given (one frame behind whatever `begin_shadow_pass`
	runs with this frame, since it runs first by convention -- imperceptible
	at any real frame rate, and simpler than threading a position through an
	API the plan deliberately kept parameterless). A spotlight needs none of
	that: it already has a real position and direction, so its frustum is
	built from those directly, at a field of view matching its own cone.
*/
begin_shadow_pass :: proc(slot: int = 0) -> bool {
	r := &mbi.renderer
	s := &r.lighting.shadow

	if !r.frame_active do return false
	if slot < 0 || slot >= MAX_SHADOW_CASTERS do return false

	if !s.settings.enabled || s.caster_indices[slot] < 0 {
		if slot == 0 && !s.warned {
			log.warn("begin_shadow_pass: shadows are not enabled, or no light is marked casts_shadow -- skipped")
			s.warned = true
		}
		return false
	}
	if slot == 0 do s.warned = false

	caster  := r.lighting.light_data[s.caster_indices[slot]]
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
		eye        = center - direction * s.settings.far * 0.5
	}

	// look_at_matrix degenerates when `up` is parallel to the direction it is
	// squared against -- a light pointing straight up or down. {0,0,1} is
	// never parallel to a direction whose y is ±1, so it is the fallback
	// rather than a second special case to keep in step with the first.
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(direction, up)) > 0.99 {
		up = {0, 0, 1}
	}

	settings := s.settings
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

	s.view_projections[slot] = proj * view
	s.active_slot            = slot

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = s.textures[slot],
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
