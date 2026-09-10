package matchbox

import "core:log"
import "core:math"

import sdl "vendor:sdl3"

/*
	The post chain
	--------------
	What happens to the HDR scene target between the last 3D draw and the
	picture, and -- more to the point -- the shape that lets more than one
	thing happen there.

	Before this file, exactly one thing did: `resolve_tonemap` (tonemap.odin)
	read the HDR target, applied exposure and a curve, and wrote the
	destination. One pass, one source, one destination, no room for a second
	step. Bloom does not fit in that shape at all -- it is a threshold, five
	downsamples, five upsamples and a composite -- so this phase's real
	deliverable is the chain, not the effect that motivated it.

	**The rule this chain is built on, stated once: a stage that needs a pass
	gets one; a stage that is a per-pixel function of one texel does not.**

	It is worth writing down because the obvious reading of "post chain" --
	a list of effects, each its own pass, each reading the last one's output
	through a pair of ping-pong buffers -- is the wrong shape here, and
	expensively so. A full-screen `RGBA16_FLOAT` ping-pong pair is two more
	scene-sized textures and a full read-modify-write of both per stage, and
	*nothing that grading or exposure does needs it*: `color_grade` is a
	function from one colour to one colour, so running it in a pass of its own
	buys a texture, a pass, and a round trip through memory in exchange for
	nothing at all. What genuinely needs a pass is a stage that reads texels
	its output does not correspond to -- a blur, a downsample, anything with a
	kernel -- because there is no way to see a neighbour's finished value from
	inside the draw that produces your own.

	So the chain today is:

		volumetric (volumetric.odin) -- one pass, additive into the HDR target
		bloom (bloom.odin)      -- 1 + 2*(levels-1) passes, its own targets
		  the tonemap resolve   -- one pass, and the end of the chain:
		      bloom composite
		      exposure
		      the Tonemap curve
		      colour grading     (color_grade_apply, below)
		      the gamma encode

	`exposure` and `tonemap` stayed on `Lighting_Settings` rather than moving
	in beside `bloom` and `grade` here, and that is the same rule applied to
	the API: they are two parameters of the resolve stage, which already
	existed, not stages of their own. Moving them would also have silently
	changed what every `Lighting_Settings{... exposure = 1 ...}` literal in
	the repo meant, for a tidier-looking struct and no behaviour.

	**Nothing here knows which `Render_Pipeline_Kind` ran.** The chain starts
	from `Renderer.lighting.targets.color`, which `FORWARD`, `CLUSTERED` and
	`DEFERRED` all finish having written -- `lighting_plan.md` section 4 asks
	post-processing not to assume a pipeline upstream, and here that is true
	by construction rather than by discipline, because the chain runs after
	`end_drawing_3d` has already closed whichever passes that pipeline opened.

	**`draw_post` (render_target.odin) is a different thing and stays one.**
	That applies one `Post_Effect` to a `Render_Target` a game owns, in the
	swapchain's own format, after the frame is otherwise finished -- a look
	filter on a finished picture. This chain runs inside the 3D pass's own
	resolve, on unbounded linear light, and a game never names its stages
	individually. The two would only merge if `Post_Effect` ever needed the
	HDR values, which none of PSX, VHS or NONE does.
*/

/*
	The stages of the post chain that a game configures -- see this file's own
	top comment for what is in the chain and what deliberately is not.

	Rides on `Lighting_Settings` (`post`) rather than having a `set_post` of
	its own, because it is scene state in exactly the sense the rest of that
	struct is: set once, changed when the look changes, and read by the same
	resolve that already reads `exposure` and `tonemap`.
*/
Post_Settings :: struct {
	bloom: Bloom,
	grade: Color_Grade,
}

/*
	Colour grading: lift/gamma/gain, contrast, saturation, in that order.

	**Every field is a delta from identity, so `Color_Grade{}` is an exact
	no-op** -- `saturation = 0` is "leave it alone", `saturation = -1` is
	fully greyscale, `saturation = 1` is twice as saturated. That is the
	spelling every photo tool uses for a slider, and it is also the answer to
	the trap `lighting_settings_normalized`'s own doc comment (lighting.odin)
	describes: a partial composite literal naming two fields leaves the rest
	at zero, and if these were *factors* a caller who wrote
	`{enabled = true, contrast = 0.2}` would get `gain = 0` and a black
	screen.

	The alternative was a sentinel -- zero read as "not set" and replaced with
	1, the way `exposure` is. It fails the test that rule sets for itself: a
	sentinel must not collide with a value somebody could legitimately mean,
	and `saturation = 0` (greyscale) and `contrast = 0` (flat grey) are both
	real answers a game could want. Deltas remove the collision instead of
	arbitrating it, and cost one addition per field in the shader.

	`enabled` is kept even though the zero value is already a no-op, so that
	"is grading on" is a statement rather than something emergent from whether
	any field happens to be non-zero -- `lighting_rework.md` section 1's whole
	complaint about the old lighting. It buys something real too: a game can
	toggle its grade off and back on without stashing and restoring six
	values, and the shader gets a uniform branch it can skip the work behind.

	What each one does, running in this order (`color_grade_apply` below, and
	`color_grade` in shaders/tonemap.frag.hlsl, which mirrors it):

	- `gain` scales -- highlights move most, black stays black. This is also
	  the colour-filter knob: `gain = {0.1, 0, -0.1}` warms the picture.
	- `lift` adds -- shadows move most, and a positive lift is the faded,
	  milky-black look.
	- `gamma` bends the midtones without moving either end.
	- `contrast` pushes away from mid grey (0.5), or toward it when negative.
	- `saturation` pushes away from the Rec. 709 luminance of the colour.
*/
Color_Grade :: struct {
	enabled: bool,

	// rgb, each a delta from identity. See the field list in this struct's
	// own doc comment for what each does; all three are [3]f32 because a
	// grade is per-channel or it is not a grade -- a single scalar gain is
	// exposure, which lives on Lighting_Settings already.
	lift:  [3]f32,
	gamma: [3]f32,
	gain:  [3]f32,

	contrast:   f32,
	saturation: f32,
}

/*
	A picture with neither bloom nor a grade -- what every scene got before
	this phase, and what a `Lighting_Settings` that never mentions `post`
	still gets. `LIGHTING_DEFAULTS` names it explicitly rather than relying on
	the zero value, for the same reason `BUTTON_STYLE` (ui.odin) exists: the
	default is a thing with a name that can be read, not an absence.

	`BLOOM_DEFAULTS` is the counterpart to reach for -- `post = {bloom =
	mb.BLOOM_DEFAULTS}` is bloom switched on with sensible numbers, and is
	what an example should say rather than filling in four fields by hand.
*/
POST_DEFAULTS :: Post_Settings{}

/*
	Zero means the default, applied to `Post_Settings` -- see
	`lighting_settings_normalized` (lighting.odin) for the rule itself.

	`grade` has no entry here and never will: every one of its fields is a
	delta from identity (see `Color_Grade`), so its zero value is already
	exactly what a caller who did not fill it in meant. That is the shape to
	prefer whenever a new settings field can be expressed that way -- a
	normalization entry is what you write when it cannot be.
*/
@(private)
post_settings_normalized :: proc(settings: Post_Settings) -> Post_Settings {
	s := settings
	s.bloom = bloom_settings_normalized(s.bloom)
	return s
}

/*
	Runs every stage of the chain that needs a pass of its own, in order,
	between the last 3D draw and the tonemap resolve. Called by
	`end_drawing_3d` (render3d.odin) once the 3D pass -- whichever pipeline
	opened it -- has been closed.

	Nothing is returned: each stage leaves its output where the resolve knows
	to look for it (`bloom_output`), which is what keeps `resolve_tonemap`
	from having to be handed a growing list of textures as stages are added.

	A stage that is a per-pixel function of one texel does not belong here at
	all -- it belongs inside the resolve. See this file's own top comment for
	that rule and why it is the one being followed.
*/
@(private)
post_chain_run :: proc() {
	/*
		Volumetric light before bloom, and the order is a decision rather than
		an accident: it adds scene light *into* the HDR target, so running it
		first is what lets a shaft bright enough to blow out spill like
		anything else bright. Reversed, bloom would read a buffer the shafts
		were not in yet and they would sit on top of the picture looking
		pasted on.

		It is also the one stage here that is configured somewhere else --
		`Lighting_Settings.volumetric` rather than `Post_Settings` -- because
		it consumes the light list and the shadow maps rather than the
		finished buffer. See volumetric.odin's own top comment. That is a
		seam worth keeping straight: *where a stage runs* and *what a stage
		is* are different questions, and this file answers only the first.
	*/
	volumetric_run()

	bloom_run()
}

/*
	One full-screen quad, reading `source` and writing `dest`, in a render pass
	of its own -- the shape every stage of the chain has, and the shape SSAO's
	own two passes (`ssao.odin`) have as well, which is why this is named for
	what it does rather than for the first thing that wanted it.

	Its own pass rather than the frame's, and its own binds rather than
	`bind_quad_state`'s, for one reason: every other quad in this package draws
	into `current_color_texture()`, and each of these draws into a texture of
	its own. `r.pass` is nil throughout wherever this is called from -- the
	callers all run between two passes, never inside one -- so nothing here
	disturbs the bind cache that the next pass to open will reset anyway.

	`load` is false for a pass that writes every texel of its destination, and
	true for one that blends into what is already there (the bloom chain's
	upsample -- see bloom_upsample.frag.hlsl). Discarding rather than loading
	where it is safe to is not a micro-optimization on a tiler: it is the
	difference between a pass that reads the whole destination back from memory
	and one that does not.

	Everything reads through `linear_clamp_sampler`. Every caller so far wants
	bilinear filtering of an internal texture whose edges are edges -- a bloom
	level being magnified, a depth buffer being tapped between texels -- and a
	wrapping sampler would fetch the far side of the screen at every border
	pixel. A caller that ever wants nearest gets a parameter then, not now.
*/
@(private)
fullscreen_pass :: proc(
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
		log.errorf("could not open a fullscreen pass: %s", sdl.GetError())
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

// -----------------------------------------------------------------------
// Colour grading, CPU side
// -----------------------------------------------------------------------

/*
	Mirrors `color_grade` in `shaders/tonemap.frag.hlsl`, statement for
	statement -- the same arrangement `tonemap_apply` (tonemap.odin) already
	has with that file's tonemap curves, and for the same reason: there is no
	GPU and no capture tooling in this environment, so the shader itself
	cannot be run and checked. What can be checked is that this side produces
	the numbers `post_test.odin` derives independently, which proves the
	*intended* arithmetic and leaves only "the shader text matches it" to a
	side-by-side read.

	Keep the two textually parallel rather than merely equivalent. A change on
	one side without the other is a silently wrong grade, which is exactly the
	class of bug neither `odin check` nor `dxc` can see.

	Takes the [0, 1] output of a tonemap curve and returns a value that may
	briefly leave that range -- the `saturate` both sides apply afterwards is
	written at the call site (`tonemap_apply`) rather than in here, so the
	arithmetic being compared is the grade itself.
*/
@(private)
color_grade_apply :: proc(color: [3]f32, grade: Color_Grade) -> [3]f32 {
	if !grade.enabled do return color

	c := color

	for i in 0 ..< 3 {
		c[i] = c[i] * (1 + grade.gain[i]) + grade.lift[i]

		// Lift can push a channel negative and a negative to a fractional
		// power is undefined. Applied whether or not the pow below runs, so
		// that skipping it changes nothing but the pow.
		c[i] = max(c[i], 0)
	}

	/*
		**Skipped entirely at the zero value, and that is not an
		optimization.** `pow(x, 1)` is not exactly `x` -- it is
		`exp2(log2(x))` on both sides of this mirror, and 0.001 comes back as
		0.0009999871. Small enough never to be seen, but `Color_Grade`'s whole
		design rests on the claim that its zero value is an *exact* no-op, and
		a claim that is only nearly true is one nobody can test. The branch is
		on a uniform, so it costs nothing per pixel either.

		max() on the divisor because a gamma delta at or below -1 would divide
		by zero or turn the curve inside out. Mirrors the shader's own guard.
	*/
	no_gamma := [3]f32{0, 0, 0}
	if grade.gamma != no_gamma {
		for i in 0 ..< 3 {
			c[i] = math.pow(c[i], 1.0 / max(1 + grade.gamma[i], 1e-4))
		}
	}

	/*
		**Written as a delta rather than as `(c - 0.5) * (1 + contrast) + 0.5`,
		which is the same arithmetic and is not an identity at zero.** Going
		out to -0.499 and back loses the low bits of a small channel: 0.001
		comes back as 0.0009999871. The form below adds exactly zero when
		`contrast` is zero, so the guarantee `Color_Grade` makes about its own
		zero value holds by construction rather than to within a tolerance --
		and it is one multiply-add either way, so it costs nothing to prefer.

		Algebraically identical: c + (c - 0.5)k = c(1 + k) - 0.5k, and
		(c - 0.5)(1 + k) + 0.5 = c(1 + k) - 0.5(1 + k) + 0.5 = c(1 + k) - 0.5k.
	*/
	for i in 0 ..< 3 {
		c[i] = c[i] + (c[i] - 0.5) * grade.contrast
	}

	// Rec. 709, matching the primaries the rest of this package assumes --
	// see the shader's own comment for why a flat average of the three
	// channels would desaturate blue and green the wrong way round.
	luma := 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]

	// The same delta form, for the same reason -- `luma + (c - luma) * (1 + s)`
	// is the usual spelling and cancels the same way at s = 0.
	for i in 0 ..< 3 {
		c[i] = c[i] + (c[i] - luma) * grade.saturation
	}

	return c
}
