package matchbox

/*
	Reflection probes -- what the room looks like from over there
	--------------------------------------------------------------
	P4 gave the scene one environment probe: a single bake of the sky,
	sampled by every surface everywhere. That is right for the sky and wrong
	for a room. A wall two metres from a red curtain should pick up red;
	the same wall at the other end of the building should not, and with one
	scene-wide probe both get the same answer.

	This is P7c: several probes, each with a **position** and a **radius**,
	blended per fragment by how far inside each one's influence that fragment
	sits. `lighting_rework.md` section 5 asks for exactly that -- "extending
	P4's `Environment_Probe` from one scene-wide bake to localized probes with
	blending between them".

	**They are captured from the scene, not from the sky**, which is the part
	that makes them worth having. A probe renders the room from its own
	position, six faces at ninety degrees, and then convolves that capture
	into the same irradiance/prefiltered pair P4 already bakes from a skybox.
	A probe baked from the sky would be the same picture wherever you stood,
	and blending identical probes is a no-op.

	**The game drives the capture**, because Matchbox does not hand a game's
	procedure back to it (CLAUDE.md's no-callbacks rule) and a capture has to
	draw the game's own scene:

		for face in 0 ..< 6 {
			if mb.begin_probe_capture(index, face) {
				draw_my_scene()
				mb.end_probe_capture()
			}
		}
		mb.bake_reflection_probe(index)

	That is `begin_shadow_pass`/`end_shadow_pass`'s exact shape, and for the
	same reason: the framework owns the pass, the target and the camera; the
	game owns what goes in it. A capture is not a per-frame cost -- bake once
	at load, or when something large moves.

	**How blending works, and what it costs.** Each probe has a radius and a
	`falloff` fraction: full influence inside `radius * (1 - falloff)`, fading
	to nothing at `radius`. A fragment sums every probe that reaches it,
	weighted, and normalizes. Where the weights do not add up to 1 -- outside
	every probe, or in the fade at the edge of one -- the remainder falls back
	to the scene-wide probe P4 already provides (`set_environment_probe`), so
	"probes where you placed them, sky everywhere else" is the default
	behaviour rather than something a game has to arrange.

	**What is approximated, and it is the usual list.** A probe is a point
	sample of a volume, so a surface halfway between two of them gets a mix of
	two wrong answers rather than the right one. There is no parallax
	correction -- the reflection is addressed as though the room were
	infinitely far away, so a mirror-flat floor will not show the wall where
	the wall actually is. Captures do not see each other, so a probe baked
	before its neighbour misses that neighbour's bounce. Each of those has a
	standard fix and each wants a frame to judge against.

	**Nothing here has been seen to render.**
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	How many localized probes a scene can have at once.

	4 rather than a larger number, and the number is load-bearing in three
	places at once: it sizes the layer count of both shared texture arrays
	(`MAX_REFLECTION_PROBES * 6` and `* 6 * levels`), it sizes
	`Probe_Frag_Data`'s own two arrays, and it is the loop bound every
	fragment pays for -- the blend below is `O(probes)` per pixel, unlike the
	light list, which `CLUSTERED` can cull. Four is enough for a room with
	corners that differ and few enough that the loop is not worth culling.

	An array size, so CLAUDE.md's "no loose constants" carves it out the same
	way `MAX_CASCADES` and `MAX_BLOOM_LEVELS` already are. It must equal
	`MAX_REFLECTION_PROBES_HLSL` (lighting_core.hlsli), which only this
	comment keeps it in step with -- the same arrangement
	`MAX_CASCADES`/`MAX_CASCADES_HLSL` already has.
*/
@(private)
MAX_REFLECTION_PROBES :: 4

/*
	One localized probe: where it is, how far it reaches, and how sharply its
	influence ends.

	`radius` is in world units and is the whole extent of the influence
	sphere -- a fragment further away than this gets nothing from this probe.
	`falloff` is the fraction of that radius spent fading, so 0 is a hard
	edge (visible as a seam where one probe's answer becomes another's) and 1
	fades from the very centre. The default of 0.25 means full influence out
	to three quarters of the radius and a fade over the last quarter, which is
	the shape that hides the seam without washing the probe out.

	No texture handles here: every probe's baked maps live in the two shared
	arrays `Reflection_Probes` owns, indexed by the probe's own slot. That is
	what keeps the sampler count flat as probes are added -- four probes cost
	the same two samplers one does, and the alternative (a texture pair per
	probe) would have run into Vulkan's per-stage floor of 16 at the third
	one.
*/
Reflection_Probe :: struct {
	position: [3]f32,
	radius:   f32,
	falloff:  f32,
}

// A probe with a sensible fade. `position` and `radius` have no default worth
// naming -- a probe is entirely defined by where it is and how far it reaches
// -- so `add_reflection_probe` takes those and defaults only this.
REFLECTION_PROBE_FALLOFF :: f32(0.25)

/*
	Every localized probe's baked maps, in two shared texture arrays, plus the
	cube the capture pass renders into on the way to them.

	`irradiance` is `MAX_REFLECTION_PROBES * 6` layers, addressed
	`probe * 6 + face`; `prefiltered` is `MAX_REFLECTION_PROBES * 6 * levels`,
	addressed `probe * 6 * levels + level * 6 + face`. Both extend P4's own
	layer scheme by one term rather than replacing it -- see
	`probe_layer_uv`'s own doc comment (lighting_core.hlsli) for the face
	addressing this builds on, and `Environment_Probe` (ambient.odin) for why
	a `Texture2DArray` rather than a hardware cube map in the first place.

	`capture`/`capture_depth` are scratch, reused by every probe in turn: a
	real `.CUBE` colour target and a matching depth buffer, at
	`settings.prefilter_resolution`. **A cube rather than an array here, and
	this is the one place in the package that renders into cube faces.** The
	two convolution shaders P4 wrote sample a `TextureCube` (they were written
	against a skybox), and reusing them unchanged is worth more than avoiding
	the one unverifiable assumption -- that a backend honours
	`GPUColorTargetInfo.layer_or_depth_plane` for a cube's own faces. Note
	that is a *colour* target, which is where that field is specified to work;
	section 7.7's caution was about the depth-target case. It has not been
	confirmed on hardware, because nothing here can confirm anything on
	hardware.
*/
@(private)
Reflection_Probes :: struct {
	irradiance:  ^sdl.GPUTexture,
	prefiltered: ^sdl.GPUTexture,

	capture:       ^sdl.GPUTexture,
	capture_depth: ^sdl.GPUTexture,

	probes: [MAX_REFLECTION_PROBES]Reflection_Probe,
	count:  int,

	settings: Environment_Probe_Settings,

	// Which slot the open capture pass belongs to, and -1 when none is open.
	// Two fields rather than one so that a mismatched
	// begin_probe_capture/end_probe_capture pair is a caught mistake rather
	// than a silently wrong bake.
	capturing_probe: int,
	capturing_face:  int,
}

/*
	Places a probe and hands back its slot, or -1 when the scene already has
	`MAX_REFLECTION_PROBES` of them.

	Placing one does **not** bake it: the slot's maps are whatever was last
	written there, which for a fresh slot is nothing at all. Call
	`begin_probe_capture`/`end_probe_capture` for each of its six faces and
	then `bake_reflection_probe` -- see this file's own top comment for the
	loop. Split that way for the same reason `create_environment_probe` and
	`set_environment_probe` are split: placing is cheap and baking is not, and
	a game re-baking a probe when a door opens should not also have to move it.

	`radius` is in world units. A probe with a radius that reaches nothing is
	not an error, it is a probe nobody stands in.
*/
add_reflection_probe :: proc(position: [3]f32, radius: f32, falloff: f32 = REFLECTION_PROBE_FALLOFF) -> int {
	p := &mbi.renderer.lighting.reflection

	if p.count >= MAX_REFLECTION_PROBES {
		log.warnf("cannot add a reflection probe: the scene already has %d, which is MAX_REFLECTION_PROBES", MAX_REFLECTION_PROBES)
		return -1
	}

	index := p.count
	p.probes[index] = Reflection_Probe{
		position = position,
		radius   = max(radius, 0),
		falloff  = clamp(falloff, 0, 1),
	}
	p.count += 1

	return index
}

/*
	Forgets every placed probe. The textures behind them are kept rather than
	released -- a scene that clears and re-places probes (a level change) will
	want the identical arrays back, and they are sized by
	`MAX_REFLECTION_PROBES` rather than by the count, so there is nothing to
	resize.

	The stale layers are not cleared either, and do not need to be: a slot
	past `count` is never sampled, because the blend loop stops at `count`.
*/
clear_reflection_probes :: proc() {
	p := &mbi.renderer.lighting.reflection
	p.probes = {}
	p.count  = 0
}

// How many probes the scene currently has placed. Mostly for an example that
// wants to say so on screen.
get_reflection_probe_count :: proc() -> int {
	return mbi.renderer.lighting.reflection.count
}

// -----------------------------------------------------------------------
// Capture
// -----------------------------------------------------------------------

/*
	Opens a pass rendering face `face` of probe `index`'s own capture cube,
	from the probe's position, at a ninety-degree field of view. Draw the
	scene into it exactly as you would into `begin_drawing_3d`, then call
	`end_probe_capture`.

	Returns false and opens nothing when the index or face is out of range,
	when there is no frame in progress, or when the textures could not be
	made -- so the `if` around it is not decoration, it is what keeps
	`draw_model`'s own "there must be a pass open" assertion honest, the same
	shape `begin_shadow_pass` already has.

	**The capture is a plain forward draw**, whatever `Render_Pipeline_Kind`
	the scene is otherwise using. A G-buffer fill would need four more targets
	at cube-face resolution and a lighting pass of its own, for a picture that
	is about to be convolved down to a 16x16 irradiance map -- and the
	clustered light list is built for the *camera's* frustum, not this one.
	The mesh pipelines are built against the HDR format (`init.odin`) and the
	capture cube is in that format for exactly this reason, so the same
	pipelines bind here unchanged.

	**Six passes, and they are not free.** This is a load-time operation, or
	a when-something-large-moves one. Nothing stops a game calling it every
	frame; it will simply render its scene seven times.
*/
begin_probe_capture :: proc(index: int, face: int) -> bool {
	r := &mbi.renderer
	p := &r.lighting.reflection

	if !r.frame_active || r.cmd == nil do return false
	if index < 0 || index >= p.count do return false
	if face < 0 || face >= 6 do return false

	ensure(p.capturing_probe < 0, "probe captures do not nest -- end_probe_capture first")
	ensure(!r.mode_3d, "begin_probe_capture cannot be called inside begin_drawing_3d")

	if !ensure_reflection_targets() do return false

	// Whatever pass belonged to something else is not this one's.
	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	color := sdl.GPUColorTargetInfo{
		texture              = p.capture,
		layer_or_depth_plane = u32(face),
		clear_color          = {0, 0, 0, 1},
		load_op              = .CLEAR,
		store_op             = .STORE,
	}

	depth := sdl.GPUDepthStencilTargetInfo{
		texture     = p.capture_depth,
		clear_depth = 1,
		load_op     = .CLEAR,
		store_op    = .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, &color, 1, &depth)
	if r.pass == nil {
		log.errorf("could not open a probe capture pass: %s", sdl.GetError())
		return false
	}

	bind_cache_reset()

	camera := probe_capture_camera(p.probes[index].position, face)

	r.mode_3d         = true
	r.view_projection = camera3d_view_projection(camera)
	r.camera3d        = camera

	p.capturing_probe = index
	p.capturing_face  = face

	// The scene block, for this camera rather than the game's -- so a
	// capture's own specular highlights and fog are computed from where the
	// probe is standing, which is the entire point of it standing there.
	push_lighting(camera)

	return true
}

// Closes the capture pass opened by `begin_probe_capture`. The face is
// complete and will be read by the next `bake_reflection_probe`.
end_probe_capture :: proc() {
	r := &mbi.renderer
	p := &r.lighting.reflection

	if p.capturing_probe < 0 do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	r.mode_3d = false

	p.capturing_probe = -1
	p.capturing_face  = -1
}

/*
	The camera face `face`'s capture is rendered with: at `position`, looking
	along `shadow_cube_face_direction`'s own axis for that face, ninety
	degrees across and square.

	**The same (direction, up) pair the cube shadow maps use**, and that is
	not tidiness -- `probe_layer_uv` (lighting_core.hlsli) addresses a baked
	face by that convention at read time, so a capture rendered with any other
	basis would be written rotated relative to how it is later sampled. The
	same agreement `probe_face_vert_data` (ambient.odin) already has to keep
	for the skybox bake, stated again here because there are now two places
	that have to keep it.

	`near` is deliberately small: a probe usually sits in open space, and a
	near plane at the usual 0.1 would clip a wall the probe is standing close
	to out of its own capture -- which reads as a hole in the reflection
	rather than as a clipping artifact.
*/
@(private)
probe_capture_camera :: proc(position: [3]f32, face: int) -> Camera3D {
	direction, up := shadow_cube_face_direction(face)

	return Camera3D{
		position   = position,
		target     = position + linalg.normalize(direction),
		up         = up,
		fov        = 90,
		projection = .PERSPECTIVE,
		near       = 0.05,
		far        = 200,
	}
}

// -----------------------------------------------------------------------
// Baking
// -----------------------------------------------------------------------

/*
	Convolves whatever the six capture passes left in the capture cube into
	probe `index`'s own slice of the two shared arrays: one irradiance face
	per face, and one prefiltered face per roughness level per face.

	The same two shaders `create_environment_probe` (ambient.odin) uses for
	the skybox bake, unchanged -- they sample a `TextureCube` and integrate
	over it, and they do not care whether that cube holds a sky or a room. All
	that differs is where the result is written: into a slot of a shared array
	rather than into a texture of the probe's own.

	Runs on its own command buffer and submits immediately, the same shape the
	skybox bake has, because it is a load-time operation rather than part of a
	frame -- and because a game calling this outside `begin_drawing`/
	`end_drawing` (which is the ordinary case) has no frame command buffer to
	record into.
*/
bake_reflection_probe :: proc(index: int) -> bool {
	r := &mbi.renderer
	p := &r.lighting.reflection

	if r.device == nil do return false
	if index < 0 || index >= p.count do return false
	if p.capture == nil || p.irradiance == nil || p.prefiltered == nil do return false

	ensure(p.capturing_probe < 0, "bake_reflection_probe cannot run while a capture pass is open")

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil do return false

	level_count := max(p.settings.prefilter_level_count, 1)

	source := sdl.GPUTextureSamplerBinding{texture = p.capture, sampler = r.linear_clamp_sampler}

	for face in 0 ..< 6 {
		vert_data := probe_capture_face_basis(face)

		target := sdl.GPUColorTargetInfo{
			texture              = p.irradiance,
			layer_or_depth_plane = u32(reflection_probe_irradiance_layer(index, face)),
			load_op              = .DONT_CARE,
			store_op             = .STORE,
		}

		pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
		if pass == nil {
			_ = sdl.CancelGPUCommandBuffer(cmd)
			return false
		}

		sdl.BindGPUGraphicsPipeline(pass, r.pipelines.probe_irradiance)
		sdl.BindGPUFragmentSamplers(pass, 0, &source, 1)
		sdl.PushGPUVertexUniformData(cmd, 0, &vert_data, size_of(vert_data))
		sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
		sdl.EndGPURenderPass(pass)
	}

	for level in 0 ..< level_count {
		// 0 at level 0 (a mirror) up to 1 at the last, matching how
		// pbr_environment_specular turns roughness back into a level.
		roughness := f32(level) / f32(max(level_count - 1, 1))
		frag_data := Probe_Prefilter_Frag_Data{roughness = roughness}

		for face in 0 ..< 6 {
			vert_data := probe_capture_face_basis(face)

			target := sdl.GPUColorTargetInfo{
				texture              = p.prefiltered,
				layer_or_depth_plane = u32(reflection_probe_layer(index, level, face, level_count)),
				load_op              = .DONT_CARE,
				store_op             = .STORE,
			}

			pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
			if pass == nil {
				_ = sdl.CancelGPUCommandBuffer(cmd)
				return false
			}

			sdl.BindGPUGraphicsPipeline(pass, r.pipelines.probe_prefilter)
			sdl.BindGPUFragmentSamplers(pass, 0, &source, 1)
			sdl.PushGPUVertexUniformData(cmd, 0, &vert_data, size_of(vert_data))
			sdl.PushGPUFragmentUniformData(cmd, 0, &frag_data, size_of(frag_data))
			sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
			sdl.EndGPURenderPass(pass)
		}
	}

	return sdl.SubmitGPUCommandBuffer(cmd)
}

/*
	The (right, up, forward) basis `skybox.vert.hlsl` needs to draw face
	`face`'s own ninety-degree view during the convolution.

	A duplicate of `probe_face_vert_data` (ambient.odin), which is
	`@(private = "file")` there. Copied rather than promoted: that one is part
	of the skybox bake's own story and this is part of this file's, the two
	must stay identical, and the thing that actually keeps them identical is
	that both are derived from `shadow_cube_face_direction` by the same three
	lines rather than from each other. Promoting it would make the coupling
	invisible instead of removing it.
*/
@(private)
probe_capture_face_basis :: proc(face: int) -> Skybox_Vert_Data {
	direction, up_hint := shadow_cube_face_direction(face)

	forward := linalg.normalize(direction)
	right   := linalg.normalize(cross3(forward, up_hint))
	up      := cross3(right, forward)

	return Skybox_Vert_Data{
		right   = {right.x, right.y, right.z, 0},
		up      = {up.x, up.y, up.z, 0},
		forward = {forward.x, forward.y, forward.z, 0},
	}
}

// -----------------------------------------------------------------------
// The layer arithmetic, and the blend weight
// -----------------------------------------------------------------------

/*
	Which layer of `Reflection_Probes.prefiltered` holds probe `probe`'s
	roughness level `level`, face `face`.

	**Named rather than written inline, because two files have to agree on
	it** -- `bake_reflection_probe` below writes there and
	`reflection_probe_specular` (lighting_core.hlsli) reads back with the
	identical expression spelled out separately in HLSL. They cannot share
	code across the language boundary, so what is possible is to have exactly
	one copy on this side and a test (`reflection_test.odin`) that checks it
	against the layout stated in prose rather than against either copy. A
	disagreement here does not fail: probe 2 quietly reflects probe 1.

	The layout is probe-major, then level, then face -- so one probe's layers
	are contiguous, which is what makes "probe `n` starts at `n * 6 * levels`"
	true and the whole thing checkable by a sweep.
*/
@(private)
reflection_probe_layer :: proc(probe, level, face, level_count: int) -> int {
	levels := max(level_count, 1)
	return probe * 6 * levels + level * 6 + face
}

// The same, for the irradiance array -- which has one face-set per probe and
// no roughness levels at all, since a diffuse convolution has no roughness to
// vary.
@(private)
reflection_probe_irradiance_layer :: proc(probe, face: int) -> int {
	return probe * 6 + face
}

/*
	How much of a probe reaches a fragment `distance` away from it -- 1 well
	inside, 0 at or past `radius`, and a smoothstep between.

	Mirrors `reflection_probe_weight` in `lighting_core.hlsli` statement for
	statement, the arrangement `tonemap_apply`, `color_grade_apply` and
	`bloom_prefilter_weight` all already have with their own shaders: the
	shader cannot be run here, so what gets checked is that the intended
	arithmetic is right, leaving only "the shader text matches it" to a
	side-by-side read.

	The shape matters more than it looks. A linear ramp joined to the plateau
	has a derivative that jumps at the join, and a derivative jump in a
	lighting term reads as a *ring* on a flat wall -- visible, and much harder
	to diagnose than a value that is simply wrong. smoothstep meets the
	plateau flat.
*/
@(private)
reflection_probe_weight_at :: proc(distance, radius, falloff: f32) -> f32 {
	if radius <= 0 do return 0
	if distance >= radius do return 0

	f     := clamp(falloff, 0, 1)
	inner := radius * (1 - f)

	// A hard-edged probe has inner == radius, and a smoothstep between two
	// equal edges is undefined -- returned early rather than nudged, so a
	// caller asking for a hard edge gets one.
	if distance <= inner do return 1
	if inner >= radius   do return 1

	t := clamp((distance - inner) / (radius - inner), 0, 1)
	return 1 - t * t * (3 - 2 * t)
}

// -----------------------------------------------------------------------
// Storage
// -----------------------------------------------------------------------

/*
	Makes the two shared arrays and the capture pair, once, at the resolution
	`settings` asks for.

	Sized by `MAX_REFLECTION_PROBES` rather than by how many probes are
	actually placed, so adding a probe never reallocates and never invalidates
	what the other slots already hold. The cost of that is that a scene with
	one probe pays for four slots' worth of layers -- at the default 16x16
	irradiance and 32x32 prefiltered over five levels, all four probes come to
	well under a megabyte together, which is cheaper than the bookkeeping a
	growing array would need.
*/
@(private)
ensure_reflection_targets :: proc() -> bool {
	r := &mbi.renderer
	p := &r.lighting.reflection

	if r.device == nil do return false
	if p.irradiance != nil && p.prefiltered != nil && p.capture != nil do return true

	if p.settings.prefilter_level_count == 0 do p.settings = ENVIRONMENT_PROBE_DEFAULTS

	irradiance_size := max(p.settings.irradiance_resolution, 1)
	prefilter_size  := max(p.settings.prefilter_resolution, 1)
	level_count     := max(p.settings.prefilter_level_count, 1)

	format := r.lighting.targets.format
	if format == .INVALID {
		format = pick_hdr_format()
		r.lighting.targets.format = format
	}

	err: Error

	if p.irradiance == nil {
		p.irradiance, err = create_cube_array_render_target(
			irradiance_size, MAX_REFLECTION_PROBES * 6, format)
		if err != nil do return false
	}

	if p.prefiltered == nil {
		p.prefiltered, err = create_cube_array_render_target(
			prefilter_size, MAX_REFLECTION_PROBES * 6 * level_count, format)
		if err != nil do return false
	}

	if p.capture == nil {
		// A real cube, unlike the two arrays above -- see Reflection_Probes'
		// own doc comment for why this one is the exception.
		p.capture = sdl.CreateGPUTexture(r.device, {
			type                 = .CUBE,
			format               = format,
			usage                = {.COLOR_TARGET, .SAMPLER},
			width                = u32(prefilter_size),
			height               = u32(prefilter_size),
			layer_count_or_depth = 6,
			num_levels           = 1,
		})

		if p.capture == nil {
			log.errorf("could not create the reflection capture cube: %s", sdl.GetError())
			return false
		}
	}

	if p.capture_depth == nil {
		if r.depth_format == .INVALID do r.depth_format = pick_depth_format()

		p.capture_depth = sdl.CreateGPUTexture(r.device, {
			type                 = .D2,
			format               = r.depth_format,
			usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width                = u32(prefilter_size),
			height               = u32(prefilter_size),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})

		if p.capture_depth == nil {
			log.errorf("could not create the reflection capture depth: %s", sdl.GetError())
			return false
		}
	}

	return true
}

// Releases everything the probe set owns. Called from `cleanup` (init.odin).
@(private)
release_reflection_targets :: proc() {
	r := &mbi.renderer
	if r.device == nil do return

	p := &r.lighting.reflection

	if p.irradiance    != nil do sdl.ReleaseGPUTexture(r.device, p.irradiance)
	if p.prefiltered   != nil do sdl.ReleaseGPUTexture(r.device, p.prefiltered)
	if p.capture       != nil do sdl.ReleaseGPUTexture(r.device, p.capture)
	if p.capture_depth != nil do sdl.ReleaseGPUTexture(r.device, p.capture_depth)

	settings := p.settings
	p^ = {}
	p.settings        = settings
	p.capturing_probe = -1
	p.capturing_face  = -1
}

/*
	The probe block the shader reads -- packed here rather than in
	`push_lighting` so that this file owns both ends of its own layout.

	`info.x` is the count the blend loop stops at, which is what makes a slot
	past it unreadable rather than merely unwritten; `info.y` is the level
	count the specular lookup turns a roughness into, the same number
	`Scene_Frag_Data.ambient_ground.w` already carries for the scene-wide
	probe. Both are here rather than derived in the shader because neither is
	a function of anything the shader can see.
*/
@(private)
reflection_frag_data :: proc() -> Probe_Frag_Data {
	p := &mbi.renderer.lighting.reflection

	count := clamp(p.count, 0, MAX_REFLECTION_PROBES)

	/*
		Nothing has been baked -- report zero probes, so every fragment falls
		straight through to the scene-wide probe rather than sampling a slot
		nothing ever wrote.

		This is the guard that matters, and it is here rather than in the
		shader because the shader cannot tell: a layer of a texture nobody
		wrote is not detectably different from one somebody did. A game that
		places probes and forgets to bake them gets P4's picture, which is the
		right degrade.
	*/
	if p.irradiance == nil || p.prefiltered == nil do count = 0

	return reflection_pack(p.probes[:], count, p.settings.prefilter_level_count)
}

// The packing itself, split out from the state it usually reads so that
// `reflection_test.odin` can hand it a set it built rather than having to
// arrange one on `mbi`. See `Probe_Frag_Data` (types.odin) for the layout and
// why it is two parallel arrays rather than one of a wider struct.
@(private)
reflection_pack :: proc(probes: []Reflection_Probe, count: int, level_count: int) -> Probe_Frag_Data {
	data: Probe_Frag_Data

	n := clamp(count, 0, min(len(probes), MAX_REFLECTION_PROBES))

	for i in 0 ..< n {
		probe := probes[i]
		data.probes[i] = {probe.position.x, probe.position.y, probe.position.z, probe.radius}
		data.params[i] = {probe.falloff, 0, 0, 0}
	}

	levels := max(level_count, 1)
	data.info = {f32(n), f32(levels - 1), f32(levels), 0}

	return data
}

/*
	The two textures the shader samples, or the 1x1 black placeholder when no
	probe has ever been baked -- the same "always something valid bound" shape
	the shadow maps, the scene-wide probe and the AO texture already have.

	Black rather than white here, for the reason `default_probe_texture`'s own
	doc comment gives: this stands in for *emitted light*, and the identity of
	emitted light is none.
*/
@(private)
reflection_probe_textures :: proc() -> (irradiance, prefiltered: ^sdl.GPUTexture) {
	r := &mbi.renderer
	p := &r.lighting.reflection

	irradiance  = p.irradiance  if p.irradiance  != nil else r.default_probe_texture
	prefiltered = p.prefiltered if p.prefiltered != nil else r.default_probe_texture

	return
}
