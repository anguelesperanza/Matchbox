package matchbox

/*
	SSAO -- screen-space ambient occlusion
	--------------------------------------
	How much of the sky a point can actually see. A crease between a wall and
	a floor receives less ambient light than the open floor beside it does,
	because most of the directions it could have received light from are
	blocked by the wall -- and no amount of light *sources* fixes that,
	because ambient light has no source to shadow. This is the module that
	puts the contact darkening back.

	**It is lighting, not post, and that is why it lives on
	`Lighting_Settings` rather than on `Post_Settings`.** The obvious place
	for a screen-space effect is the post chain, and it is the wrong one: what
	this produces is a value for `Surface.occlusion`, which the BRDFs have
	multiplied their ambient term by since P0. Applying it after shading
	instead would darken direct light and emissive along with ambient, which
	is not what an occluded crease does -- a torch held to that crease still
	lights it. See `post.odin`'s own top comment for the boundary this sits on
	the other side of: the post chain consumes the finished HDR buffer, and
	this has to be known before the buffer exists.

	**The asymmetry between pipelines is the design problem of this phase**,
	and `lighting_rework.md` section 5 flagged it in advance rather than
	leaving it to be discovered. Occlusion has to be known *before* shading,
	and the two pipeline families learn the scene's depth at different times:

	- `DEFERRED` already has it. The G-buffer fill pass writes depth to
	  `Gbuffer_Targets.depth` and the lighting pass runs afterward, so the AO
	  pass slots between the two and costs one fullscreen pass.
	- `FORWARD` and `CLUSTERED` shade *during* the geometry pass, so the depth
	  they produce arrives a pass too late to use. They need a **depth
	  prepass** -- the geometry drawn once with a fragment shader that writes
	  nothing, then AO, then the real pass. See `pipeline_forward.odin`.

	Both then read one AO texture in one shared place: `shade_surface`
	(lighting_core.hlsli) multiplies it into `surface.occlusion` before
	anything else runs. **One line, one file, both pipelines** -- which is the
	property that made `Surface` worth building, tested a third way.

	**What is approximated, and it is a lot.** This is a hemisphere-sampling
	SSAO of the ordinary kind: it knows only what is on screen, so an occluder
	just off the edge of the frame stops occluding and the darkening visibly
	changes as you turn. Normals are reconstructed from depth rather than read
	from a G-buffer (see `ssao.frag.hlsl`), which costs accuracy at
	silhouettes and buys one code path instead of two. It is not a
	ground-truth ambient occlusion and it is not GTAO; it is the cheap
	approximation that has been in every real-time renderer since 2007.

	**Nothing here has been seen to render.**
*/

import "core:log"
import "core:math"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	How many hemisphere taps `ssao.frag.hlsl` can ever take per pixel.

	32 rather than a larger number because the cost is linear in it and the
	quality is not -- past about 24 the difference is noise the blur pass
	removes anyway. An array size, both here and in the shader's own kernel
	array, so CLAUDE.md's "no loose constants" carves it out the same way
	`MAX_CASCADES` and `MAX_BLOOM_LEVELS` already are.
*/
@(private)
MAX_SSAO_SAMPLES :: 32

/*
	Ambient occlusion from the depth buffer. Off by default; `enabled` is the
	whole switch.

		mb.set_lighting({
			enabled  = true,
			exposure = 1,
			ambient  = {kind = .HEMISPHERE, color = SKY, ground_color = GROUND},
			ssao     = mb.SSAO_DEFAULTS,
		})

	**It does nothing visible in a scene with no ambient light**, which is the
	first thing to check when it looks like it is not working: occlusion
	multiplies the ambient term, and `Ambient{}` -- the zero value, and what
	every example had before P4 -- is no ambient light at all. There is
	nothing there to occlude.

	`radius` is the world-space size of the hemisphere sampled around each
	point, and is the number to reach for first: it is how far away something
	has to be before it stops shadowing. Small values (a few centimetres)
	give tight contact shadows in corners; large values darken whole concave
	regions and start to look like a smudge. It is in world units, so a scene
	built at a different scale needs a different number.

	`intensity` scales the result -- 1 is the occlusion the sampling actually
	found, above that is an exaggeration, below is a softening. `bias` is the
	depth offset that keeps a flat surface from occluding itself through
	floating-point error in the reconstruction; too little gives a dark grain
	over flat walls, too much eats the contact shadow the effect exists for.
	It is the same trade `Shadow_Bias` (shadow.odin) documents, one buffer
	over, and it is in world units too.

	`samples` is taps per pixel, and `blur` is the radius in texels of the
	pass that removes the sampling noise those taps leave -- 2 is a 5x5 box,
	0 skips the blur pass entirely and is worth trying only to see what the
	blur is for.
*/
Ssao :: struct {
	enabled:   bool,
	radius:    f32,
	intensity: f32,
	bias:      f32,
	samples:   int,
	blur:      int,
}

/*
	SSAO switched on, with numbers for a scene built at roughly human scale --
	a half-metre hemisphere, occlusion taken at the strength it was measured
	at, and enough taps that the blur has something to work with.

	`bias = 0.02` is two centimetres at that scale. Like every bias in this
	package it is the one number that genuinely depends on the depth format
	the device handed back (`pick_depth_format`, render3d.odin): a `D16_UNORM`
	device has far less precision to lose and may need more. Nothing here can
	measure that.
*/
SSAO_DEFAULTS :: Ssao{enabled = true, radius = 0.5, intensity = 1, bias = 0.02, samples = 16, blur = 2}

/*
	The AO texture and the one it is blurred into -- both single-channel, both
	full resolution.

	**Full resolution rather than the half most engines use.** Half-res AO is
	the standard optimization and it needs a depth-aware upsample to avoid
	haloing on silhouettes, which is a third pass and a set of decisions that
	want a frame to look at. Full res is one fewer thing to be wrong about
	while nothing can be seen, and the note is here so a later phase knows
	what was left on the table rather than assuming it was overlooked.

	`raw` is what `ssao.frag.hlsl` writes and `blurred` is what
	`ssao_blur.frag.hlsl` writes; `ssao_output` picks between them, since
	`Ssao.blur = 0` skips the second pass entirely.
*/
@(private)
Ssao_Targets :: struct {
	raw:     ^sdl.GPUTexture,
	blurred: ^sdl.GPUTexture,
	format:  sdl.GPUTextureFormat,

	width, height: i32,
}

/*
	Zero means the default -- see `lighting_settings_normalized` (lighting.odin)
	for the rule.

	A disabled `Ssao` is left exactly as it came, the same first line
	`shadow_settings_normalized` and `bloom_settings_normalized` both open
	with, so `Ssao{}` is a fixed point and `LIGHTING_DEFAULTS` can be read off
	its own constant.

	`blur` is the one field with a legitimate zero -- "do not blur" is a real
	answer, and a useful one for seeing what the blur is doing -- so it is
	taken literally. Every other field is a number with no meaning at zero: a
	zero radius samples a single point, zero intensity is `enabled = false`
	spelled expensively, zero samples is a divide by zero, and a zero bias is
	the self-occlusion grain the bias exists to remove.
*/
@(private)
ssao_settings_normalized :: proc(settings: Ssao) -> Ssao {
	s := settings
	if !s.enabled do return s

	if s.radius    == 0 do s.radius    = SSAO_DEFAULTS.radius
	if s.intensity == 0 do s.intensity = SSAO_DEFAULTS.intensity
	if s.bias      == 0 do s.bias      = SSAO_DEFAULTS.bias
	if s.samples   == 0 do s.samples   = SSAO_DEFAULTS.samples

	s.samples = clamp(s.samples, 1, MAX_SSAO_SAMPLES)
	s.blur    = clamp(s.blur, 0, 8)

	return s
}

/*
	Whether anything this frame is going to read the scene's depth back after
	the 3D pass has closed -- which is what decides whether that pass stores
	its depth or discards it (`begin_drawing_3d`).

	One procedure rather than the condition written out at each site, because
	both of P7b's effects read it and the two must not be able to disagree: a
	pass that discarded its depth and an effect that reads it is a frame of
	garbage, not a compile error.
*/
@(private)
scene_depth_is_read :: proc() -> bool {
	settings := mbi.renderer.lighting.settings
	return settings.ssao.enabled || settings.volumetric.enabled
}

/*
	This frame's depth, whichever texture the running pipeline actually wrote
	it into -- the one place that difference is resolved, so nothing
	downstream of it needs to know which pipeline ran.

	`DEFERRED` writes the scene's geometry into its own G-buffer depth target
	and leaves `Renderer.depth_texture` holding only what its *final* pass
	drew (the skybox and any transparent parts), so reading the latter under
	that pipeline would give an almost-empty depth buffer. Getting this
	backwards would not fail, it would just quietly produce no occlusion,
	which is why it is one procedure rather than a condition repeated at each
	caller.
*/
@(private)
scene_depth_texture :: proc() -> ^sdl.GPUTexture {
	r := &mbi.renderer

	if r.lighting.settings.pipeline == .DEFERRED {
		return r.lighting.gbuffer.depth
	}

	if r.target != nil do return r.target.depth
	return r.depth_texture
}

// The AO texture's own format. Single channel, and asked for rather than
// assumed the way every other format in this package is -- `R8_UNORM` as a
// sampled colour target is about as universally supported as a format gets,
// but "near-universal" is what `pick_hdr_format`'s own comment says too, and
// it still asks.
@(private)
pick_ssao_format :: proc() -> sdl.GPUTextureFormat {
	if sdl.GPUTextureSupportsFormat(mbi.renderer.device, .R8_UNORM, .D2, {.COLOR_TARGET, .SAMPLER}) {
		return .R8_UNORM
	}

	// The HDR target's own format is the fallback rather than another 8-bit
	// one: it is already known to work as a sampled colour target on this
	// device (the whole 3D pass renders into it), so this cannot fail twice.
	log.warn("this device does not support R8_UNORM as a colour target; SSAO will use the HDR format instead")
	return mbi.renderer.lighting.targets.format
}

// Makes sure both AO textures exist at the size of the current 3D
// destination. "Recreate rather than resize", the same shape
// `ensure_hdr_texture` (tonemap.odin) and `ensure_bloom_targets` (bloom.odin)
// already have, for the same reason: a GPU texture has no resize.
@(private)
ensure_ssao_targets :: proc() -> bool {
	r := &mbi.renderer
	if r.device == nil do return false

	size := get_current_target_size()
	width, height := i32(size.x), i32(size.y)
	if width <= 0 || height <= 0 do return false

	s := &r.lighting.ssao
	if s.raw != nil && s.width == width && s.height == height do return true

	release_ssao_targets()

	if s.format == .INVALID do s.format = pick_ssao_format()

	s.raw     = create_ssao_texture(width, height)
	s.blurred = create_ssao_texture(width, height)

	if s.raw == nil || s.blurred == nil {
		log.errorf("could not create the SSAO targets: %s", sdl.GetError())
		release_ssao_targets()
		return false
	}

	s.width, s.height = width, height
	return true
}

@(private)
create_ssao_texture :: proc(width, height: i32) -> ^sdl.GPUTexture {
	r := &mbi.renderer

	return sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = r.lighting.ssao.format,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
}

// Releases both AO textures. Called on a resize, when SSAO is switched off,
// and from `cleanup` (init.odin).
@(private)
release_ssao_targets :: proc() {
	r := &mbi.renderer
	if r.device == nil do return

	s := &r.lighting.ssao
	format := s.format // survives, since the device's answer cannot change

	if s.raw     != nil do sdl.ReleaseGPUTexture(r.device, s.raw)
	if s.blurred != nil do sdl.ReleaseGPUTexture(r.device, s.blurred)

	s^ = {}
	s.format = format
}

/*
	What `shade_surface` samples -- the blurred AO if the blur pass ran, the
	raw AO if `Ssao.blur` is 0, and nil when SSAO is off or the pass did not
	complete this frame.

	Nil is not a failure to handle at the call site: the binding code puts
	`Renderer.default_texture` (1x1 **white**) in the slot instead, and white
	is 1.0, which is exactly "nothing is occluded". That is the same
	always-something-valid-bound shape the shadow maps and the probe slots
	already have -- and white rather than the black `default_probe_texture`
	for the same reason the material textures use white: this is a *factor*,
	and the identity of a factor is one.
*/
@(private)
ssao_output :: proc() -> ^sdl.GPUTexture {
	r := &mbi.renderer
	if !r.lighting.settings.ssao.enabled do return nil

	s := &r.lighting.ssao
	if s.raw == nil do return nil

	return s.blurred if r.lighting.settings.ssao.blur > 0 else s.raw
}

// -----------------------------------------------------------------------
// The sample kernel
// -----------------------------------------------------------------------

/*
	The hemisphere `ssao.frag.hlsl` samples, worked out here and pushed as a
	uniform array rather than generated in the shader.

	**Deterministic and low-discrepancy, not random.** The classic
	implementation fills this with uniform random directions at startup, which
	means the pattern differs between runs and cannot be asserted on at all.
	A Hammersley sequence gives a better-distributed set for the same count
	*and* makes the whole thing a pure function of `count` -- which is what
	lets `ssao_test.odin` check the properties this has to have (every sample
	inside the unit hemisphere, every one on the +Z side, lengths rising
	toward the rim) rather than taking them on trust.

	**The lengths are deliberately not uniform.** Biasing them toward the
	origin packs most of the taps close to the point being shaded, where the
	occlusion that matters is: a crease is dark because of what is a few
	centimetres away, not because of what is at the far edge of the radius.
	Uniform lengths spend most of the samples on the outer shell, which is
	where they matter least and where the screen-space approximation is
	weakest anyway.

	**The radius comes off a third, independent coordinate, and that is a fix
	rather than a flourish.** It was `0.1 + 0.9 * (i/n)^2` -- driven by the
	index, which also drives the azimuth -- so a sample's angle around the
	normal and its distance from it rose together and the whole tap set was a
	**spiral**. Measured: the correlation between the two was 0.965.

	A rigid spiral is the worst possible shape here, because every pixel
	rotates this set by its own angle before sampling. When the taps are a
	spiral, the occlusion a pixel measures is a strong, smooth function of
	that rotation -- so whatever structure the per-pixel rotation has prints
	straight through into the image, and `interleaved_gradient_noise`
	(ssao.frag.hlsl) has a great deal of structure: it is a fine diagonal
	weave, which is exactly what the first render of it looked like. Taking
	the radius from base 3 while the azimuth comes from the index drops the
	correlation to under 0.25 and leaves the rotation with far less to bite
	on.

	The old shape also had a test asserting it -- lengths rising monotonically
	with index -- which is worth remembering: a test can pin a defect in place
	just as firmly as it pins a property.

	Returns a fixed-size array rather than a slice -- a slice of a local would
	borrow this procedure's own stack frame, which Odin rejects.
*/
@(private)
ssao_kernel :: proc(count: int) -> [MAX_SSAO_SAMPLES][4]f32 {
	kernel: [MAX_SSAO_SAMPLES][4]f32

	n := clamp(count, 1, MAX_SSAO_SAMPLES)

	for i in 0 ..< n {
		// A Halton triple: the index walks evenly, and bases 2 and 3 give two
		// further coordinates that spread independently of it and of each
		// other. Three coordinates because three things need deciding -- which
		// way round the normal, how far up the hemisphere, and how far out --
		// and any two of them sharing a source is a pattern.
		u1 := (f32(i) + 0.5) / f32(n)
		u2 := radical_inverse(u32(i), 2)
		u3 := radical_inverse(u32(i), 3)

		// Cosine-weighted over the +Z hemisphere: more taps where the
		// surface actually gathers light, which is the same weighting the
		// ambient term this multiplies is itself an integral of.
		phi       := 2 * math.PI * u1
		cos_theta := math.sqrt(1 - u2)
		sin_theta := math.sqrt(max(1 - cos_theta * cos_theta, 0))

		direction := [3]f32{math.cos(phi) * sin_theta, math.sin(phi) * sin_theta, cos_theta}

		// 0.1 near the centre out to 1 at the rim, squared so the near taps
		// outnumber the far ones -- see this proc's own doc comment for why
		// the coordinate driving it must not be the one driving `phi`.
		scale := 0.1 + 0.9 * u3 * u3

		kernel[i] = {direction.x * scale, direction.y * scale, direction.z * scale, 0}
	}

	return kernel
}

/*
	The van der Corput sequence: index `i`'s digits in `base`, reflected about
	the point and read back as a fraction. 1 in base 2 is 0.5, 2 is 0.25, 3 is
	0.75; in base 3, 1 is 1/3 and 2 is 2/3.

	General in the base since P7c, where the SSAO kernel needed a second one
	(base 3) to decide a tap's radius independently of its angle. It was a
	base-2-only bit-reversal before that -- five shifts and masks, which is
	the fast way and only ever ran at most 32 times at load, so generality is
	the better trade.

	`base` must be at least 2; a base of 0 or 1 has no digits to reflect and
	the loop below would not terminate.
*/
@(private)
radical_inverse :: proc(index: u32, base: u32) -> f32 {
	if base < 2 do return 0

	result   := f32(0)
	fraction := f32(1) / f32(base)

	i := index
	for i > 0 {
		result   += f32(i % base) * fraction
		fraction /= f32(base)
		i        /= base
	}

	return result
}

// -----------------------------------------------------------------------
// The passes
// -----------------------------------------------------------------------

/*
	Builds this frame's AO texture: one sampling pass over the depth buffer,
	then one blur pass to take the sampling noise off it.

	Called from wherever the running pipeline has depth but has not yet
	shaded -- `pipeline_deferred_end` between the G-buffer fill and the
	lighting pass, `end_drawing_3d` between the depth prepass and the scene
	pass for `FORWARD`/`CLUSTERED`. Both hand it the same camera, and it does
	not know or care which called it.

	Both passes go through `fullscreen_pass` (post.odin), which is the same
	procedure the bloom chain's own stages use -- it was named `bloom_pass`
	until this phase wanted the identical twenty lines, and a second copy
	under a different name was the worse answer.
*/
@(private)
ssao_run :: proc(camera: Camera3D) {
	r := &mbi.renderer
	if !r.frame_active || r.cmd == nil do return

	settings := r.lighting.settings.ssao

	if !settings.enabled {
		if r.lighting.ssao.raw != nil do release_ssao_targets()
		return
	}

	depth := scene_depth_texture()
	if depth == nil do return
	if !ensure_ssao_targets() do return

	s := &r.lighting.ssao

	defaults := camera3d_defaults(camera)
	view_projection := camera3d_view_projection(camera)

	forward := camera3d_forward(camera)
	size    := [2]f32{f32(s.width), f32(s.height)}

	frag_data := Ssao_Frag_Data{
		inverse_view_projection = linalg.matrix4_inverse(view_projection),
		view_projection         = view_projection,

		camera  = {camera.position.x, camera.position.y, camera.position.z, f32(settings.samples)},
		forward = {forward.x, forward.y, forward.z, settings.radius},
		params  = {settings.bias, settings.intensity, 1.0 / size.x, 1.0 / size.y},

		// z: 1 for an orthographic camera, 0 for a perspective one. The
		// reconstruction below needs to know which, for exactly the reason
		// `cluster_index_for_fragment` (lighting_core.hlsli) does -- see
		// `Scene_Frag_Data.shadow_caster1`'s own comment on the same value,
		// and P5's own note in lighting_rework.md section 5 on the frame it
		// silently got wrong.
		screen = {size.x, size.y, 1 if defaults.projection == .ORTHOGRAPHIC else 0, 0},

		kernel = ssao_kernel(settings.samples),
	}

	if !fullscreen_pass(r.pipelines.ssao, depth, s.raw, {s.width, s.height}, &frag_data, size_of(frag_data), false) {
		release_ssao_targets()
		return
	}

	if settings.blur <= 0 do return

	blur_data := Ssao_Blur_Frag_Data{
		texel  = {1.0 / size.x, 1.0 / size.y},
		radius = f32(settings.blur),
	}

	if !fullscreen_pass(r.pipelines.ssao_blur, s.raw, s.blurred, {s.width, s.height}, &blur_data, size_of(blur_data), false) {
		release_ssao_targets()
	}
}
