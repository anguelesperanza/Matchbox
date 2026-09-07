package matchbox

/*
	Shadows
	-------
	Whether an occluder actually blocks a light, for the one light a game
	names as the caster.

	**Directional only.** A point light's shadow needs a cubemap -- six depth
	renders instead of one, since the light radiates every direction rather
	than down one axis -- and nothing here builds that. Marking a point light
	`casts_shadow` is silently ignored by `recompute_shadow_caster`
	(light.odin), the same degrade an unsupported combination gets elsewhere
	in this package rather than an error.

	**One shadow map, one caster, opt-in twice over.** A light needs
	`casts_shadow = true` *and* a game needs to call `enable_shadows` -- see
	`Light`'s own doc comment in light.odin for why marking a light alone is
	harmless. This mirrors how lighting itself only replaces the fixed
	fallback shading once a light is actually set, and how fog is its own
	`set_fog`/`disable_fog` switch: nothing here changes what an existing
	game looks like unless it asks.

	**Explicit, not folded into `begin_drawing_3d`.** A game calls
	`begin_shadow_pass`/`end_shadow_pass` itself, drawing whatever should
	cast a shadow in between, before its normal `begin_drawing_3d` block --
	the same shape `begin_drawing_target`/`draw_post` (render_target.odin)
	already externalizes a render-to-texture pass to the caller rather than
	hiding it inside another procedure.
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

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
	Turns shadows on: builds a real shadow map at `settings.resolution` and
	replaces whatever texture was bound in its place -- the 1x1 placeholder
	`init` made, or an earlier real map from a previous call with different
	settings.

	Casts nothing by itself. A light also needs `casts_shadow = true` (see
	`Light`), and `begin_shadow_pass`/`end_shadow_pass` need to actually run
	each frame around whatever should cast one -- this only says a shadow map
	should exist and be trusted once it does.
*/
enable_shadows :: proc(settings: Shadow_Settings = SHADOW_DEFAULTS) {
	r := &mbi.renderer
	if r.device == nil do return

	size := max(settings.resolution, 1)

	if r.shadow.texture != nil {
		sdl.ReleaseGPUTexture(r.device, r.shadow.texture)
	}

	r.shadow.texture = sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = r.shadow.format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = u32(size),
		height               = u32(size),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})

	if r.shadow.texture == nil {
		log.errorf("could not create a shadow map: %s", sdl.GetError())
		r.shadow.enabled = false
		return
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

is_shadows_active :: proc() -> bool {
	return mbi.renderer.shadow.enabled
}

/*
	Opens the shadow pass: works out the shadow-casting light's own
	view-projection, then a depth-only render pass against the shadow map,
	ready for whatever `draw_model` calls come next to render into it as
	occluders rather than as the visible scene.

	**Returns whether it actually opened one.** `false` when there is nothing
	to render -- `enable_shadows` was never called, or no light is currently
	marked `casts_shadow` (`recompute_shadow_caster`, light.odin) -- which is
	an ordinary state for a game that has not turned shadows on yet, not a
	mistake, but `draw_model` still asserts loudly if asked to draw with no
	pass of the right kind open. A caller that draws inside this block has to
	check the return value for exactly that reason:

		if mb.begin_shadow_pass() {
			mb.draw_model_at(occluder, position, scale)
			mb.end_shadow_pass()
		}

	Logged once per change of state rather than every frame a game leaves
	shadows off -- see `r.shadow.warned` below.

	**Centred on the camera, not the scene.** A directional light has no
	position of its own to build a frustum around, and this renderer has no
	scene bounds to ask for one either. The last camera position
	`begin_drawing_3d` was given is one frame behind whatever
	`begin_shadow_pass` is called with this frame (it runs first, by
	convention) -- imperceptible at any real frame rate, and simpler than
	threading a position through an API the plan deliberately kept
	parameterless.
*/
begin_shadow_pass :: proc() -> bool {
	r := &mbi.renderer
	if !r.frame_active do return false

	if !r.shadow.enabled || r.shadow.caster_index < 0 {
		if !r.shadow.warned {
			log.warn("begin_shadow_pass: shadows are not enabled, or no light is marked casts_shadow -- skipped")
			r.shadow.warned = true
		}
		return false
	}
	r.shadow.warned = false

	caster    := r.lighting.lights[r.shadow.caster_index]
	direction := linalg.normalize(caster.target.xyz - caster.position.xyz)

	// look_at_matrix degenerates when `up` is parallel to the direction it is
	// squared against -- a light pointing straight up or down. {0,0,1} is
	// never parallel to a direction whose y is ±1, so it is the fallback
	// rather than a second special case to keep in step with the first.
	up := [3]f32{0, 1, 0}
	if abs(linalg.dot(direction, up)) > 0.99 {
		up = {0, 0, 1}
	}

	settings := r.shadow.settings
	center   := r.camera3d.position
	eye      := center - direction * settings.far * 0.5

	view := look_at_matrix(eye, eye + direction, up)
	proj := ortho(-settings.extent, settings.extent, -settings.extent, settings.extent, settings.near, settings.far)
	r.shadow.view_projection = proj * view

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = r.shadow.texture,
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
