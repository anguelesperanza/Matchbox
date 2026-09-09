package matchbox

/*
	Bloom
	-----
	Bright light spilling into what is next to it -- the first stage of the
	post chain, and the reason `post.odin` exists at all: it is the effect
	that does not fit in one pass.

	**How it is built, and why it is not a blur.** A gaussian wide enough to
	read as bloom at 1080p is several hundred taps, per pixel, per frame. The
	way every engine actually does it is a chain of half-resolution images:
	threshold the scene once, shrink it five times, then walk back up folding
	each level into the one above it. Each level's own small kernel covers
	twice the *screen* distance the level below it did, so five cheap kernels
	between them have the skirt of one enormous one. What it costs is that the
	skirt is a stack of overlapping blurs rather than a real gaussian, which
	is visible only if you go looking for it.

	The passes, per frame, for `levels` levels:

		prefilter   HDR target -> level 0    (13-tap downsample + the knee)
		downsample  level i    -> level i+1  (13-tap)             x levels-1
		upsample    level i+1  -> level i    (3x3 tent, mixed)    x levels-1

	so 1 + 2*(levels-1) passes, and level 0 is what the tonemap resolve
	composites. The kernels themselves are in `shaders/bloom.hlsli`; the
	weights are mirrored here, as literals, so `post_test.odin` has two
	independently-typed copies to compare rather than one checked against
	itself.

	**The way back up mixes rather than adds, and that is the one place this
	chain differs from the presentations it is taken from.** Both kernels sum
	to 1, so every level holds the same total light as the level below it;
	summing them into level 0 would put `levels` copies of the scene's bright
	light there, which makes a flat bright wall come out brighter from a
	6-level chain than a 4-level one and leaves `intensity` meaning nothing
	fixed. `Bloom.scatter` is the mix weight instead, so the total stays at
	exactly one copy however many levels there are -- `levels` decides how
	wide, `intensity` decides how strong, and neither moves the other. See
	`bloom_upsample.frag.hlsl`, which is where the blend that does it lives.

	**Why a texture per level rather than one texture's mip chain.** SDL_GPU
	will happily render into a chosen mip level (`GPUColorTargetInfo.mip_level`),
	so the mip-chain version is expressible and would use less memory. It also
	means every downsample reads mip i of the same texture it is writing mip
	i+1 of, which is a read-write hazard on one resource -- legal only if the
	backend inserts the barrier, and not something that can be confirmed
	without a GPU to run it on. There is none here. A texture per level
	sidesteps the question entirely for `MAX_BLOOM_LEVELS` allocations that
	together come to under half a screen's worth of pixels (1/4 + 1/16 + ...
	converges to 1/3), which is a cheap way to buy a guarantee -- the same
	trade `lighting_rework.md` section 7.7 records for `Texture2DArray` over
	`TextureCube`.

	**What is deliberately not here.** No Karis luminance average inside the
	downsample, so a single very bright pixel can still flicker as it moves
	(`bloom_prefilter.frag.hlsl` documents where it would go). No dirt mask,
	no lens flare, no per-level weighting. Each of those wants a rendered
	frame to tune against and there is none in this environment; a stated gap
	is worth more than a guessed constant. **Nothing here has been seen to
	render.**
*/

import "core:log"

import sdl "vendor:sdl3"

/*
	How many levels the bloom chain can ever have.

	8 is past the point of usefulness at any resolution this framework will
	meet -- level 8 of a 3840-wide image is 15 pixels across, and the last
	couple of levels of any chain contribute a nearly-flat wash. An array
	size, so CLAUDE.md's "no loose constants" carves it out the same way
	`MAX_CASCADES` and `MAX_SHADOW_CASTERS` already are.
*/
@(private)
MAX_BLOOM_LEVELS :: 8

/*
	Bright light spilling into what is next to it. Off by default; `enabled`
	is the whole switch, and every other field is inert while it is false.

		mb.set_lighting({
			enabled  = true,
			exposure = 1,
			tonemap  = .ACES,
			post     = {bloom = mb.BLOOM_DEFAULTS},
		})

	`threshold` is in linear light, not in display values, which is the whole
	reason this belongs on the HDR side of the resolve: 1.0 means "brighter
	than white", so with the default only light that would have clipped blooms
	at all. Lower it toward 0 for the dreamy look where everything glows a
	little. **Zero is taken literally** -- it is a real answer (bloom
	everything), so it is not read as "not set", and `{enabled = true}` on its
	own therefore gives a soft overall glow rather than nothing. `knee` is how
	far below `threshold` the fade-in starts, in the same units; 0 is a hard
	edge, which makes a surface drifting past the threshold pop rather than
	fade.

	`intensity` is how much of the blurred result is added back on top of the
	scene, and `levels` is how many times the image is halved -- more levels
	is a wider, softer skirt, and genuinely *only* that, which is what the
	mixing upsample buys (see this file's own top comment). `scatter` is how
	that fixed amount of light is distributed between the tight levels and
	the wide ones: 0 is the tightest halo the chain can make, 1 is the widest
	and softest, and the total added back is the same either way.

	`intensity`, `scatter` and `levels` all have no sensible zero while
	`enabled` is true -- a bloom that adds nothing, spreads nothing, or has no
	chain is spelled `enabled = false` -- so all three take their defaults
	from `BLOOM_DEFAULTS` when left at zero. See `bloom_settings_normalized`,
	including the one wart that creates.
*/
Bloom :: struct {
	enabled:   bool,
	threshold: f32,
	knee:      f32,
	intensity: f32,
	scatter:   f32,
	levels:    int,
}

/*
	Bloom switched on, with numbers that suit an HDR scene: only light past
	white spills, it fades in over the half-stop below that, and what comes
	back is a subtle halo rather than a glow.

	`intensity = 0.05` looks small and is not -- the chain preserves total
	light, so level 0 holds the *same* light that passed the knee, spread
	out. Adding 5% of it back is already a clearly visible halo around
	anything bright; 1.0 would be a white screen.

	`scatter = 0.7` leans toward the wider levels, which is the halo most
	people mean by "bloom". It is the one number here picked by convention
	rather than derived, since picking it properly needs a frame to look at.
*/
BLOOM_DEFAULTS :: Bloom{enabled = true, threshold = 1, knee = 0.5, intensity = 0.05, scatter = 0.7, levels = 5}

/*
	The chain's own textures -- one per level, each half the width and half the
	height of the one before it, all in the HDR target's own float format
	(`Lighting_Targets.format`, tonemap.odin) because a bloom level holds
	unbounded linear light exactly as the scene target does.

	`width`/`height` are the *source* size these were built for, not level 0's
	own size, so `ensure_bloom_targets` can tell a window resize from a
	no-op with one comparison. `count` is how many of `levels` are live, which
	is not always `Bloom.levels` -- see `bloom_level_sizes`.
*/
@(private)
Bloom_Targets :: struct {
	levels: [MAX_BLOOM_LEVELS]^sdl.GPUTexture,
	sizes:  [MAX_BLOOM_LEVELS][2]i32,
	count:  int,

	width, height: i32,
}

/*
	Zero means the default -- see `lighting_settings_normalized` (lighting.odin)
	for the rule, and `Bloom` itself for which fields it covers here and which
	are deliberately taken literally.

	`intensity` and `scatter` get the treatment and `threshold` does not,
	which looks inconsistent until you ask what a zero means in each. A zero
	threshold is "everything blooms", which is a look somebody wants; a zero
	intensity is "run eleven passes and add nothing" and a zero scatter is
	"build ten blurred levels and use none of them", both of which
	`enabled = false` already says more cheaply and more clearly.

	**The wart, stated rather than found later:** a game fading bloom out by
	animating `intensity` toward zero snaps back to 0.05 at exactly zero. The
	fix on the game's side is to fade `intensity` and then set
	`enabled = false`, which is what it wanted anyway -- but it is a real edge
	and it is the price of the sentinel. It is paid here rather than in
	`Color_Grade`, where the same trade came out the other way, because there
	the delta-from-identity spelling was available and here it is not:
	"intensity" that a caller writes as an offset from 0.05 is a worse API
	than a wart in one edge case.
*/
@(private)
bloom_settings_normalized :: proc(settings: Bloom) -> Bloom {
	s := settings

	// A disabled Bloom is left exactly as it came, so `Bloom{}` -- and
	// therefore `Post_Settings{}` and `LIGHTING_DEFAULTS` -- is a fixed point
	// of this rule rather than something that grows four numbers nothing will
	// read. `shadow_settings_normalized` (shadow.odin) opens with the
	// identical line, for the identical reason.
	if !s.enabled do return s

	if s.intensity == 0 do s.intensity = BLOOM_DEFAULTS.intensity
	if s.scatter   == 0 do s.scatter   = BLOOM_DEFAULTS.scatter
	if s.levels    == 0 do s.levels    = BLOOM_DEFAULTS.levels

	// scatter is a blend weight and nothing outside [0, 1] is one -- past 1
	// the source-alpha blend it drives would subtract the destination rather
	// than mix with it, which is a negative bloom level and then a black
	// halo. Clamped rather than rejected, since a caller reaching for 1.5
	// means "as wide as it goes".
	s.scatter = clamp(s.scatter, 0, 1)
	s.levels  = clamp(s.levels, 1, MAX_BLOOM_LEVELS)

	return s
}

/*
	How big each level of the chain is for a source of `width` by `height`,
	and how many levels there actually turn out to be.

	Level `i` is the source halved `i + 1` times, so level 0 is already half
	resolution -- the prefilter does the first halving as it goes, which is
	free (it is a downsampling kernel either way) and means the chain never
	holds a full-resolution copy of the scene.

	**The count can come back smaller than `levels` asked for**, and that is
	the whole reason this returns one. A 320x240 window runs out of pixels at
	level 6 or so, and a level that is 1x1 in both axes has nothing left to
	blur -- every further level would be the same single texel, one pass each,
	forever. So halving stops once both axes have reached 1. A caller must use
	the returned count and not its own request.

	Returns a fixed-size array rather than a slice: a slice of a local would
	borrow this procedure's stack frame, which Odin rejects outright.
*/
@(private)
bloom_level_sizes :: proc(width, height: i32, levels: int) -> ([MAX_BLOOM_LEVELS][2]i32, int) {
	sizes: [MAX_BLOOM_LEVELS][2]i32
	count := 0

	w, h := width, height
	if w <= 0 || h <= 0 do return sizes, 0

	for i in 0 ..< clamp(levels, 0, MAX_BLOOM_LEVELS) {
		w = max(w / 2, 1)
		h = max(h / 2, 1)

		sizes[i] = {w, h}
		count = i + 1

		// Nothing below a single texel to halve. Note this stops *after*
		// recording the 1x1 level rather than before it: that level is a real
		// part of the chain (it is the widest, flattest contribution), it is
		// only a further one that would be a duplicate.
		if w == 1 && h == 1 do break
	}

	return sizes, count
}

/*
	Makes sure the chain's textures exist, match the HDR target's current size
	and are as many as `levels` asks for. Recreates rather than resizes, the
	same shape `ensure_hdr_texture` (tonemap.odin) and `ensure_depth_texture`
	(render3d.odin) already have, for the same reason: a GPU texture has no
	resize.

	Rebuilt on a level-count change as well as a size change, since a game
	turning `levels` down would otherwise leave the extra textures allocated
	and -- worse -- leave `count` disagreeing with what `bloom_run` iterates.
*/
@(private)
ensure_bloom_targets :: proc(levels: int) -> bool {
	r := &mbi.renderer
	if r.device == nil do return false

	t := &r.lighting.targets
	if t.color == nil || t.width <= 0 || t.height <= 0 do return false

	b := &r.lighting.bloom

	sizes, count := bloom_level_sizes(t.width, t.height, levels)
	if count == 0 do return false

	if b.count == count && b.width == t.width && b.height == t.height && b.levels[0] != nil {
		return true
	}

	release_bloom_targets()

	for i in 0 ..< count {
		b.levels[i] = sdl.CreateGPUTexture(r.device, {
			type                 = .D2,
			format               = t.format,
			usage                = {.COLOR_TARGET, .SAMPLER},
			width                = u32(sizes[i].x),
			height               = u32(sizes[i].y),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})

		if b.levels[i] == nil {
			log.errorf("could not create bloom level %d: %s", i, sdl.GetError())
			release_bloom_targets()
			return false
		}
	}

	b.sizes  = sizes
	b.count  = count
	b.width  = t.width
	b.height = t.height

	return true
}

// Releases every level and forgets the size they were built for. Called on a
// resize, on a level-count change, and from `cleanup` (init.odin).
@(private)
release_bloom_targets :: proc() {
	r := &mbi.renderer
	if r.device == nil do return

	b := &r.lighting.bloom

	for i in 0 ..< MAX_BLOOM_LEVELS {
		if b.levels[i] != nil {
			sdl.ReleaseGPUTexture(r.device, b.levels[i])
			b.levels[i] = nil
		}
	}

	b^ = {}
}

/*
	The four numbers `bloom_prefilter.frag.hlsl` actually reads, worked out
	here rather than there: `threshold - knee`, `2 * knee`, `0.25 / knee`, and
	`threshold`.

	**The reason the shader gets these rather than a threshold and a knee is
	the third one.** `0.25 / knee` is an infinity at `knee = 0`, and a hard
	knee is a legitimate setting (see `Bloom.knee`). Computed here, the zero
	case is one branch in Odin, once per frame; computed in the shader it
	would be one branch per pixel guarding a division nobody wants to rely on
	the driver's own infinity handling for.

	With `knee = 0` the packed curve makes the shader's `soft` term clamp to
	exactly zero, leaving `max(0, brightness - threshold)` -- the plain
	subtractive threshold, which is the right hard-knee answer rather than a
	special case bolted on beside it.
*/
@(private)
bloom_prefilter_curve :: proc(threshold, knee: f32) -> [4]f32 {
	t := max(threshold, 0)
	k := max(knee, 0)

	if k == 0 do return {t, 0, 0, t}

	return {t - k, k * 2, 0.25 / k, t}
}

/*
	How much of a colour survives the knee, given its brightest channel --
	mirrors `bloom_prefilter` in `shaders/bloom_prefilter.frag.hlsl`,
	statement for statement, so `post_test.odin` has something to sweep. The
	shader multiplies a colour by this; this takes the brightness the shader
	takes the max to find.

	Scaling rather than subtracting per channel is what keeps hue: taking the
	threshold off each of r, g and b separately would walk a saturated orange
	highlight toward white as it got brighter.
*/
@(private)
bloom_prefilter_weight :: proc(brightness: f32, curve: [4]f32) -> f32 {
	soft := clamp(brightness - curve.x, 0, curve.y)
	soft = curve.z * soft * soft

	return max(soft, brightness - curve.w) / max(brightness, 1e-5)
}

/*
	The 13-tap downsample's own weights, in the order
	`shaders/bloom.hlsli` writes them: the centre tap, each of the four
	corners, each of the four edge midpoints, each of the four inner taps.

	A literal mirror of the shader's own literals, so `post_test.odin` can
	assert the kernel sums to 1 -- which is the property that makes a flat
	wall come out of the chain at the brightness it went in at. Asserting it
	against the shader's arithmetic re-derived here would only prove the code
	does what the code does; two hand-typed copies disagreeing is a real
	signal.
*/
@(private)
bloom_downsample_weights :: proc() -> [4]f32 {
	return {0.125, 0.03125, 0.0625, 0.125}
}

// The 3x3 tent's own weights -- centre, edge, corner -- over a divisor of 16.
// The same mirror, for the same reason, as `bloom_downsample_weights`.
@(private)
bloom_upsample_weights :: proc() -> [4]f32 {
	return {4.0 / 16.0, 2.0 / 16.0, 1.0 / 16.0, 0}
}

/*
	Level 0 of the chain -- what `resolve_tonemap` composites -- or nil when
	bloom is off or the chain has not been built this frame. The resolve binds
	`Renderer.default_probe_texture` (1x1 black) in that case, so the sampler
	slot always has something valid in it, the same shape the shadow maps and
	the probe slots already have.
*/
@(private)
bloom_output :: proc() -> ^sdl.GPUTexture {
	b := &mbi.renderer.lighting.bloom
	if b.count == 0 do return nil
	return b.levels[0]
}

/*
	One stage of the chain: a full-screen quad reading `source` and writing
	`dest`, in a render pass of its own.

	Its own pass rather than the frame's, and its own binds rather than
	`bind_quad_state`'s, for one reason: every other quad in this package
	draws into `current_color_texture()`, and each of these draws into a
	different bloom level. `r.pass` is nil throughout -- `end_drawing_3d`
	closed the 3D pass before the chain runs -- so nothing here disturbs the
	bind cache that the tonemap resolve's own pass will reset anyway.

	`load` is false for the two shrinking passes, which write every texel of
	their destination, and true for the upsample, which blends into what is
	already there (see `bloom_upsample.frag.hlsl`). Discarding rather than
	loading where it is safe to is not a micro-optimization on a tiler -- it
	is the difference between a pass that reads the whole destination back
	from memory and one that does not.
*/
@(private)
bloom_pass :: proc(
	pipeline:  ^sdl.GPUGraphicsPipeline,
	source:    ^sdl.GPUTexture,
	dest:      ^sdl.GPUTexture,
	dest_size: [2]i32,
	frag_data: rawptr,
	frag_size: u32,
	load:      bool,
) -> bool {
	r := &mbi.renderer

	target := sdl.GPUColorTargetInfo{
		texture  = dest,
		load_op  = .LOAD if load else .DONT_CARE,
		store_op = .STORE,
	}

	pass := sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
	if pass == nil {
		log.errorf("could not open a bloom pass: %s", sdl.GetError())
		return false
	}

	size := [2]f32{f32(dest_size.x), f32(dest_size.y)}

	// The same full-screen rectangle every resolve draws: quad.vert turns
	// position/size/screen into clip space, so "the whole destination" is the
	// destination's own size centred on its own middle.
	vert_data := Vert_Data{
		position = size * 0.5,
		size     = size,
		screen   = size,
		uv_min   = {0, 0},
		uv_max   = {1, 1},
	}

	binding := sdl.GPUTextureSamplerBinding{texture = source, sampler = r.linear_clamp_sampler}

	sdl.BindGPUGraphicsPipeline(pass, pipeline)

	vertex_binding := sdl.GPUBufferBinding{buffer = r.quad_verts, offset = 0}
	sdl.BindGPUVertexBuffers(pass, 0, &vertex_binding, 1)
	sdl.BindGPUIndexBuffer(pass, {buffer = r.quad_indices, offset = 0}, ._32BIT)

	sdl.BindGPUFragmentSamplers(pass, 0, &binding, 1)

	sdl.PushGPUVertexUniformData(r.cmd, 0, &vert_data, size_of(vert_data))
	sdl.PushGPUFragmentUniformData(r.cmd, 0, frag_data, frag_size)

	sdl.DrawGPUIndexedPrimitives(pass, 6, 1, 0, 0, 0)
	sdl.EndGPURenderPass(pass)

	return true
}

/*
	Builds the whole chain for this frame: prefilter, down, then back up.
	Called by `post_chain_run` (post.odin) from `end_drawing_3d`, after the 3D
	pass has closed and before the tonemap resolve reads the result.

	Does nothing at all when bloom is off, including allocating -- but it does
	release what a previous frame allocated, so turning bloom off gives the
	memory back rather than holding a chain nothing samples.

	`texel` for each pass is one texel of that pass's own *source*, never its
	destination; the two differ by a factor of two everywhere in here, and
	using the wrong one is a blur at half or twice the intended radius, which
	looks plausible rather than broken. That is why the sizes come out of
	`Bloom_Targets.sizes` (and the HDR target for the first one) rather than
	being recomputed inline per pass.
*/
@(private)
bloom_run :: proc() {
	r := &mbi.renderer
	settings := r.lighting.settings.post.bloom

	if !settings.enabled {
		if r.lighting.bloom.count > 0 do release_bloom_targets()
		return
	}

	t := &r.lighting.targets
	if t.color == nil do return
	if !ensure_bloom_targets(settings.levels) do return

	b := &r.lighting.bloom

	prefilter := Bloom_Prefilter_Frag_Data{
		texel = {1.0 / f32(t.width), 1.0 / f32(t.height)},
		curve = bloom_prefilter_curve(settings.threshold, settings.knee),
	}

	if !bloom_pass(r.pipelines.bloom_prefilter, t.color, b.levels[0], b.sizes[0], &prefilter, size_of(prefilter), false) {
		return
	}

	for i in 0 ..< b.count - 1 {
		down := Bloom_Filter_Frag_Data{texel = {1.0 / f32(b.sizes[i].x), 1.0 / f32(b.sizes[i].y)}}

		if !bloom_pass(r.pipelines.bloom_downsample, b.levels[i], b.levels[i + 1], b.sizes[i + 1], &down, size_of(down), false) {
			return
		}
	}

	// Back up, smallest first, each level mixing itself into the one above by
	// `scatter`. By the time this reaches level 0 it holds one copy of the
	// light that passed the knee, distributed across the levels rather than
	// summed over them -- see this file's own top comment.
	for i := b.count - 2; i >= 0; i -= 1 {
		up := Bloom_Filter_Frag_Data{
			texel   = {1.0 / f32(b.sizes[i + 1].x), 1.0 / f32(b.sizes[i + 1].y)},
			scatter = settings.scatter,
		}

		if !bloom_pass(r.pipelines.bloom_upsample, b.levels[i + 1], b.levels[i], b.sizes[i], &up, size_of(up), true) {
			return
		}
	}
}
