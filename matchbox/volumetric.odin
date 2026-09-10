package matchbox

/*
	Volumetric light -- the beam, not the surface it lands on
	---------------------------------------------------------
	Light scattering off whatever is in the air between the camera and the
	scene: shafts through a window, a cone around a spotlight, a glow around a
	street lamp in fog. Every light in this package until now lit *surfaces*
	and the space in front of them stayed empty, which is why a spotlight
	pointed past the camera has been invisible rather than a visible cone.

	**How it works, in one paragraph.** For each pixel, march from the camera
	toward whatever the depth buffer says is there. At each step, ask every
	light how much of it reaches that point in mid-air -- the same
	`sample_light` arithmetic a surface would ask, and the same
	`shadow_visibility` lookup, which is what makes a shaft take the shape of
	the window that cast it. Weight that by a phase function (how much light
	scatters *toward the camera* rather than in some other direction) and by
	how much of the air's own light is absorbed on the way back out. Sum, and
	add the result to the scene.

	**Why it is `Lighting_Settings` and not `Post_Settings`.** Same answer as
	`ssao.odin`'s: this consumes the light list and the shadow maps and
	produces scene light in linear HDR. The post chain consumes the finished
	HDR buffer. That said, it *is* a stage of the chain in the mechanical
	sense -- `post_chain_run` runs it -- and it runs before bloom on purpose,
	so that a shaft bright enough to blow out blooms like anything else that
	is.

	**Pipeline-agnostic by construction, and cheaply so.** All it needs is
	this frame's depth (`scene_depth_texture`, ssao.odin) and the light list,
	and both exist identically under all three pipelines. Unlike SSAO it needs
	nothing *before* shading -- it adds light rather than modulating it -- so
	`FORWARD` needs no prepass for it and there is no asymmetry to design
	around. It is the easy half of P7b, and worth saying so: the two effects
	the phase brief bundled together turned out to differ in exactly the way
	that mattered.

	**What is approximated.** A single uniform density everywhere, with no
	noise, no wind, no local volumes -- so it is fog with light in it rather
	than a cloud system. Marching is uniform in distance with a per-pixel
	dither, not exponential, and there is no temporal reintegration, so a low
	`steps` count shows banding that a game either raises `steps` for or hides
	under the dither. Full resolution rather than the half-res most engines
	use, for the same reason `Ssao_Targets` is: a half-res upsample that does
	not halo needs a frame to tune against.

	**Nothing here has been seen to render.**
*/

import "core:math"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	Light scattering off the air. Off by default; `enabled` is the whole
	switch.

		mb.set_lighting({
			enabled    = true,
			exposure   = 1,
			tonemap    = .ACES,
			shadows    = mb.SHADOW_DEFAULTS,
			volumetric = mb.VOLUMETRIC_DEFAULTS,
		})

	**It needs a shadow-casting light to look like anything.** Without
	shadows there is nothing to cut the beam into shafts and the result is a
	smooth haze around each light -- which is real, and is roughly what
	`Fog` already gives more cheaply. The shafts are the point, and shafts are
	shadow maps seen edge-on.

	`density` is how much light the air scatters per world unit. It does two
	opposing things at once and that is not a bug: more density means more
	light scattered toward the camera *and* more of it absorbed before it
	arrives, so raising it brightens the near air and darkens the far. Values
	are small -- 0.03 is a light haze at human scale, 0.3 is thick fog.

	`anisotropy` is the phase function's `g`: 0 scatters equally in every
	direction, positive values scatter forward so a light behind an object
	blooms around its edges as you look toward it, negative values scatter
	back. Real air and water droplets are strongly forward-scattering, which
	is why looking toward the sun through mist is bright and looking away is
	not. Must stay inside (-1, 1); the ends are a singularity.

	`steps` is how many samples each pixel takes along its ray, and is the
	whole cost of the effect -- each one is a shadow-map lookup per casting
	light. `max_distance` is where marching stops regardless of what the depth
	buffer says, so a pixel looking at the sky does not march to the far plane
	at full step count for a contribution the absorption has already killed.
	`intensity` scales the finished result.
*/
Volumetric :: struct {
	enabled:      bool,
	density:      f32,
	anisotropy:   f32,
	steps:        int,
	max_distance: f32,
	intensity:    f32,
}

/*
	Volumetric light switched on, tuned for a scene at human scale with a
	visible but not smothering haze: a light mist, strongly forward-scattering
	the way real air is, thirty-two steps out to forty units.

	`anisotropy = 0.6` is the one number here chosen by convention rather than
	derived -- it is roughly what atmospheric scattering measures at, and it
	is high enough that the difference from isotropic is obvious the first
	time a game turns this on, which matters more than accuracy for a default
	nobody has been able to look at.
*/
VOLUMETRIC_DEFAULTS :: Volumetric{enabled = true, density = 0.03, anisotropy = 0.6, steps = 32, max_distance = 40, intensity = 1}

/*
	Zero means the default -- see `lighting_settings_normalized`
	(lighting.odin). A disabled `Volumetric` is left exactly as it came, so
	`Volumetric{}` is a fixed point, the same first line
	`ssao_settings_normalized` and the other two open with.

	`anisotropy` is the deliberate exception: zero is isotropic scattering,
	which is a real and useful setting -- it is what a thick cloud does -- so
	it is taken literally. It is clamped instead, and to strictly inside
	(-1, 1) rather than to it: the Henyey-Greenstein denominator goes to zero
	at either end and the phase function becomes an infinity pointed in one
	direction.
*/
@(private)
volumetric_settings_normalized :: proc(settings: Volumetric) -> Volumetric {
	s := settings
	if !s.enabled do return s

	if s.density      == 0 do s.density      = VOLUMETRIC_DEFAULTS.density
	if s.steps        == 0 do s.steps        = VOLUMETRIC_DEFAULTS.steps
	if s.max_distance == 0 do s.max_distance = VOLUMETRIC_DEFAULTS.max_distance
	if s.intensity    == 0 do s.intensity    = VOLUMETRIC_DEFAULTS.intensity

	s.anisotropy   = clamp(s.anisotropy, -0.95, 0.95)
	s.steps        = clamp(s.steps, 1, MAX_VOLUMETRIC_STEPS)
	s.density      = max(s.density, 0)
	s.max_distance = max(s.max_distance, 0.001)

	return s
}

/*
	How many raymarch steps `volumetric.frag.hlsl` will ever take.

	256 is far past anything worth paying for -- the banding a low count
	produces is gone by about 64 with the dither on -- and it exists as a
	clamp rather than as a shader array bound, since the shader loops rather
	than indexing. It is here so that a game that types 100000 gets a frame
	rather than a hang, which is the one failure mode a step count has.
*/
@(private)
MAX_VOLUMETRIC_STEPS :: 256

// -----------------------------------------------------------------------
// The phase function, CPU side
// -----------------------------------------------------------------------

/*
	Henyey-Greenstein: how much light arriving from one direction scatters
	into another. `cos_theta` is between the direction the light is
	travelling and the direction the camera is looking; `g` is the anisotropy.

	Mirrors `volumetric_phase` in `shaders/volumetric.frag.hlsl` statement for
	statement, the same arrangement `tonemap_apply` and `color_grade_apply`
	already have with their own shaders, and for the same reason: the shader
	cannot be run here, so what gets checked is that the intended arithmetic
	is right.

	**It is normalized over the sphere**, which is the property worth having
	and the one `volumetric_test.odin` integrates numerically to confirm: the
	`1/(4*pi)` in front is what makes `g = 0` scatter a unit of light evenly
	over a unit sphere rather than over "some amount that looked right". Get
	that constant wrong and every density value means something different from
	what the comment on it says.
*/
@(private)
volumetric_phase_hg :: proc(cos_theta, g: f32) -> f32 {
	gg := g * g

	// 1 + g^2 - 2g*cos, raised to 3/2. Floored before the power because a
	// g at the ends of its range drives this to zero and a negative from
	// rounding would come back NaN -- ssao_settings_normalized's own clamp to
	// +/-0.95 is what actually keeps it away from there, and this is the belt
	// to that pair of braces.
	denom := max(1 + gg - 2 * g * cos_theta, 1e-4)

	return (1 - gg) / (4 * math.PI * denom * math.sqrt(denom))
}

/*
	How much of the light emitted at `distance` from the camera survives the
	air on the way back to it -- Beer-Lambert, `exp(-density * distance)`.

	Used twice per step in the shader and once here: the light reaching a
	point in mid-air has already crossed some air to get there, and what
	scatters off that point has to cross the rest to reach the eye. The shader
	accumulates only the second, and says why at its own call site: the first
	would need the distance from each light to each sample, which is a second
	march per light per step.
*/
@(private)
volumetric_transmittance :: proc(density, distance: f32) -> f32 {
	return math.exp(-max(density, 0) * max(distance, 0))
}

// -----------------------------------------------------------------------
// The pass
// -----------------------------------------------------------------------

/*
	Marches this frame's depth buffer and adds the in-scattered light straight
	into the HDR scene target.

	**Additive, into the target the 3D pass already wrote**, rather than into
	a texture of its own that the resolve then composites the way bloom's
	chain is. Two reasons, and the second is the real one: light scattering
	off the air *is* scene light, so it belongs on the same side of exposure
	and the tonemap curve as everything else -- and putting it in the HDR
	buffer is what lets bloom, which runs after this, spill a bright shaft the
	way it would spill anything else bright.

	Its own binding code rather than `fullscreen_pass` (post.odin), which
	binds exactly one source texture: this needs the depth buffer, four shadow
	textures, the two probe slots `lighting_core.hlsli` declares whether or
	not anything reads them, and three storage buffers. The shape below is
	`draw_deferred_lighting_quad`'s (pipeline_deferred.odin) with the G-buffer
	taken out.
*/
@(private)
volumetric_run :: proc() {
	r := &mbi.renderer
	if !r.frame_active || r.cmd == nil do return

	settings := r.lighting.settings.volumetric
	if !settings.enabled do return

	depth := scene_depth_texture()
	if depth == nil do return

	t := &r.lighting.targets
	if t.color == nil do return

	// LOAD, because the whole point is to add to what the 3D pass wrote.
	color := sdl.GPUColorTargetInfo{
		texture  = t.color,
		load_op  = .LOAD,
		store_op = .STORE,
	}

	pass := sdl.BeginGPURenderPass(r.cmd, &color, 1, nil)
	if pass == nil do return

	sdl.BindGPUGraphicsPipeline(pass, r.pipelines.volumetric)

	shadow := &r.lighting.shadow

	bindings := [7]sdl.GPUTextureSamplerBinding{
		{texture = depth,                  sampler = r.linear_clamp_sampler},
		{texture = shadow.textures[0],     sampler = shadow.sampler},
		{texture = shadow.textures[1],     sampler = shadow.sampler},
		{texture = shadow.cascade_texture, sampler = shadow.sampler},
		{texture = shadow.cube_texture,    sampler = shadow.sampler},

		// The probe pair, bound because `lighting_core.hlsli` declares it
		// unconditionally and a declared sampler must have something in it --
		// nothing in this shader's own path ever reads either one. The same
		// "always something valid bound" the shadow slots have when shadows
		// are off.
		{texture = r.lighting.probe.irradiance  if r.lighting.probe.irradiance  != nil else r.default_probe_texture, sampler = r.linear_clamp_sampler},
		{texture = r.lighting.probe.prefiltered if r.lighting.probe.prefiltered != nil else r.default_probe_texture, sampler = r.linear_clamp_sampler},
	}
	sdl.BindGPUFragmentSamplers(pass, 0, &bindings[0], 7)

	// And the AO texture lighting_core.hlsli declares, at slot 7 here --
	// equally unread by this shader, equally required to be bound.
	ssao_texture := ssao_output()
	if ssao_texture == nil do ssao_texture = r.default_texture

	ssao_binding := sdl.GPUTextureSamplerBinding{texture = ssao_texture, sampler = r.linear_clamp_sampler}
	sdl.BindGPUFragmentSamplers(pass, 7, &ssao_binding, 1)

	// And P7c's two probe arrays at 8 and 9 -- unread here for the same
	// reason the probe pair above is, and bound for the same reason: a
	// declared sampler has to have something in it.
	reflect_irradiance, reflect_prefiltered := reflection_probe_textures()
	reflect_bindings := [2]sdl.GPUTextureSamplerBinding{
		{texture = reflect_irradiance,  sampler = r.linear_clamp_sampler},
		{texture = reflect_prefiltered, sampler = r.linear_clamp_sampler},
	}
	sdl.BindGPUFragmentSamplers(pass, 8, &reflect_bindings[0], 2)

	light_buffer := r.lighting.light_buffer
	sdl.BindGPUFragmentStorageBuffers(pass, 0, &light_buffer, 1)

	cluster_ranges, cluster_light_indices := pipeline_cluster_buffers()
	ranges_buf  := cluster_ranges
	indices_buf := cluster_light_indices
	sdl.BindGPUFragmentStorageBuffers(pass, 1, &ranges_buf, 1)
	sdl.BindGPUFragmentStorageBuffers(pass, 2, &indices_buf, 1)

	size := get_current_target_size()

	frag_data := Volumetric_Frag_Data{
		// The same reconstruction ssao.frag.hlsl is handed, and for the same
		// reason -- see its own doc comment on why an inverse matrix rather
		// than a near/far linear-depth formula.
		inverse_view_projection = linalg.matrix4_inverse(r.view_projection),

		params  = {settings.density, settings.anisotropy, f32(settings.steps), settings.max_distance},
		params2 = {settings.intensity, 0, 0, 0},
	}
	sdl.PushGPUFragmentUniformData(r.cmd, 0, &frag_data, size_of(frag_data))

	vert_data := Vert_Data{
		position = size * 0.5,
		size     = size,
		screen   = size,
		uv_min   = {0, 0},
		uv_max   = {1, 1},
	}
	sdl.PushGPUVertexUniformData(r.cmd, 0, &vert_data, size_of(vert_data))

	vertex_binding := sdl.GPUBufferBinding{buffer = r.quad_verts, offset = 0}
	sdl.BindGPUVertexBuffers(pass, 0, &vertex_binding, 1)
	sdl.BindGPUIndexBuffer(pass, {buffer = r.quad_indices, offset = 0}, ._32BIT)

	sdl.DrawGPUIndexedPrimitives(pass, 6, 1, 0, 0, 0)
	sdl.EndGPURenderPass(pass)
}
