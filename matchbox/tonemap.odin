package matchbox

/*
	Tonemap
	-------
	The 3D pass's real destination, and the resolve that turns it back into
	something a display wants.

	Before this file, `shade_surface` (`lighting_core.hlsli`) applied
	`pow(color, 1.0 / 2.2)` to `BLINN_PHONG`'s own output, inline, before fog
	-- a transfer function baked into one shading model's own branch, which
	`brdf/contract.hlsli`'s doc comment already flagged as the thing standing
	in the way of a second model: whichever model came next would have had to
	decide the same question again; there is no way for a per-model branch
	to also be a shared, un-repeated answer.

	**Why an HDR target rather than just moving the `pow` call.** A single
	shared encode after the light loop still assumes every value reaching it
	is meant to become a pixel directly -- anything brighter than 1 clips
	rather than compresses, which is fine for `PsxGame`'s fixed light rig and
	wrong the moment a scene has a light bright enough to blow out. Tone
	mapping needs the *pre-clip* linear value to compress instead of clip, so
	the pass has to keep writing unbounded linear light somewhere, rather than
	clamping it to a displayable range as it goes -- which is what an
	`RGBA16_FLOAT` target is for.

	**Why this cannot simply become `Render_Target`'s own format.** SDL3
	bakes a pipeline's target format in at creation (`render_target.odin`'s
	own doc comment on why it matches the swapchain), so a target in a
	different format needs its own copy of every pipeline that draws into it.
	Making every `Render_Target` `RGBA16_FLOAT` would mean every 2D pipeline
	needs an HDR copy too, for a feature 2D drawing has no use for -- text and
	UI are not participating in tone mapping, they are drawn after
	`end_drawing_3d` once the picture is already resolved. So the float
	format stays internal to the 3D pass alone: `mesh`, `mesh_skinned`,
	`line` and both skybox pipelines are rebuilt against it (`init.odin`),
	nothing else is, and this file is the seam between the two -- the 3D pass
	writes here, `resolve_tonemap` reads it and writes wherever
	`begin_drawing_3d` was actually called for (the window, or a game's own
	`Render_Target`, both still in the swapchain's own format).

	One shared texture rather than one per destination: only one 3D pass is
	ever open at a time, so `ensure_hdr_texture` recreating this on demand to
	match whatever `begin_drawing_3d` is rendering into this frame costs
	nothing a per-destination copy would save, the same reasoning
	`ensure_depth_texture` (render3d.odin) already applies to the window's own
	depth buffer.
*/

import "core:log"
import "core:math"

import sdl "vendor:sdl3"

/*
	The 3D pass's internal destination. `format` is `.INVALID` until `init`
	picks one (`pick_hdr_format`) -- the same "asked for, not assumed" caution
	`Renderer.depth_format` and `Shadow_State.format` already take, since
	`RGBA16_FLOAT` support for `{.COLOR_TARGET, .SAMPLER}` is near-universal
	but this package does not get to assume a driver rather than ask it.
*/
Lighting_Targets :: struct {
	color:         ^sdl.GPUTexture,
	format:        sdl.GPUTextureFormat,
	width, height: i32,
}

// The float format the 3D pass renders into before the tonemap resolve --
// see this file's own top comment for why it cannot be the swapchain's own
// format. `R16G16B16A16_FLOAT` is the one candidate: every backend this
// package targets (D3D12, Vulkan, Metal) guarantees it for a sampled colour
// target, so there is no fallback list the way `pick_depth_format` and
// `pick_shadow_format` need one for formats that genuinely vary by driver --
// only the same "ask, do not assume" shape they use, in case a future target
// (mobile GLES, say) does not.
@(private)
pick_hdr_format :: proc() -> sdl.GPUTextureFormat {
	if sdl.GPUTextureSupportsFormat(mbi.renderer.device, .R16G16B16A16_FLOAT, .D2, {.COLOR_TARGET, .SAMPLER}) {
		return .R16G16B16A16_FLOAT
	}

	log.error("this device does not support a floating-point colour target; HDR rendering will not work")
	return .R16G16B16A16_FLOAT
}

/*
	Makes sure the HDR scene target exists and matches whatever destination
	`begin_drawing_3d` is rendering into this frame -- the window, or a
	game's own `Render_Target` (`get_current_target_size`,
	render_target.odin). The same "recreate rather than resize" shape
	`ensure_depth_texture` already has, for the same reason: a GPU texture has
	no resize.

	Unlike that one, a game that alternates which destination it draws 3D
	into from one frame to the next -- not a pattern any example here
	exercises -- would recreate this every such switch if the two
	destinations differ in size. Documented rather than solved: one shared
	texture is the right trade for the common case (one destination, resized
	rarely if ever), and solving the alternating case would mean either a
	texture per destination (which is most of what this file exists to avoid
	paying for) or a cache keyed on size, which is more machinery than a
	pattern nothing here actually does has earned yet.
*/
@(private)
ensure_hdr_texture :: proc() -> bool {
	r := &mbi.renderer
	if r.device == nil do return false

	size := get_current_target_size()
	width, height := i32(size.x), i32(size.y)
	if width <= 0 || height <= 0 do return false

	t := &r.lighting.targets
	if t.color != nil && t.width == width && t.height == height {
		return true
	}

	if t.color != nil {
		sdl.ReleaseGPUTexture(r.device, t.color)
		t.color = nil
	}

	if t.format == .INVALID {
		t.format = pick_hdr_format()
	}

	t.color = sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = t.format,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})

	if t.color == nil {
		log.errorf("could not create the HDR scene target: %s", sdl.GetError())
		return false
	}

	t.width, t.height = width, height
	return true
}

/*
	The inverse of `tonemap_encode`, used once: turning the ordinary "what you
	see is what you get" colour a game hands `clear_background` into the
	linear value the HDR target's own clear wants (`begin_drawing_3d`).

	Not a general sRGB decode -- 2.2 rather than the real piecewise transfer
	function, matching `tonemap_encode`'s own 1/2.2 so the two are exact
	inverses under `Tonemap.NONE` and `exposure = 1`, which is the one
	combination where a game's chosen background colour comes back out
	unchanged. Any other tonemap curve or exposure changes the background the
	same way it changes everything else drawn in the pass -- see `Fog`'s own
	doc comment (lighting.odin) for the same trade-off stated for fog.
*/
@(private)
linearize_background_color :: proc(c: [4]f32) -> [4]f32 {
	return {math.pow(max(c.x, 0), 2.2), math.pow(max(c.y, 0), 2.2), math.pow(max(c.z, 0), 2.2), c.w}
}

/*
	Tonemaps and gamma-encodes the HDR scene target, writing the result into
	whatever `begin_drawing_3d` rendered for -- the window, or a game's own
	`Render_Target`, both still in the swapchain's own format. Called once
	from `end_drawing_3d`, after that pass has closed.

	A full-screen quad through `draw_quad`, the same shape `draw_post`
	(render_target.odin) already uses to bring a `Render_Target` back to the
	window -- this is exactly that operation with a fixed effect (tonemap +
	gamma) and a fixed, internal source (the HDR target, never a game's own
	texture).

	The nearest sampler (`sprite_sampler`) is deliberate, not the linear one
	other 2D drawing uses: this quad is always exactly the size of the
	texture it reads, so nearest and linear sample the identical texel and
	nearest is the one that does not pretend otherwise.
*/
@(private)
resolve_tonemap :: proc() {
	r := &mbi.renderer
	t := &r.lighting.targets
	if t.color == nil do return

	size := get_current_target_size()

	vert_data := Vert_Data{
		position = size * 0.5,
		size     = size,
		screen   = size,
		uv_min   = {0, 0},
		uv_max   = {1, 1},
	}

	settings := r.lighting.settings
	frag_data := Tonemap_Resolve_Frag_Data{
		exposure = settings.exposure,
		tonemap  = f32(settings.tonemap),
	}

	draw_quad(r.pipelines.tonemap, &vert_data, &frag_data, size_of(frag_data), t.color, r.sprite_sampler)
}

// -----------------------------------------------------------------------
// The curves, CPU side
// -----------------------------------------------------------------------

/*
	Everything below mirrors `shaders/tonemap.frag.hlsl`'s own arithmetic,
	statement for statement, so `lighting_rework.md` section 8's verification
	standard -- numeric, not visual, wherever possible -- has something to
	assert against: there is no GPU capture tooling in this environment, so
	the shader itself cannot be run and checked from a test. What can be
	checked is that this side produces the numbers `tonemap_test.odin` works
	out independently (by hand, in Python, the same "checked against an
	independent implementation" shape the skinning palettes and skybox
	sampling already used) -- which at least proves the *intended* arithmetic
	is right, even though it cannot prove the shader text matches it beyond a
	side-by-side read.
*/

// Exposure and the negative-radiance floor every curve below assumes its
// input already has -- a BRDF can hand back a small negative value from
// floating-point error even though nothing physical is negative.
@(private)
tonemap_expose :: proc(color: [3]f32, exposure: f32) -> [3]f32 {
	return {
		max(color.x * exposure, 0),
		max(color.y * exposure, 0),
		max(color.z * exposure, 0),
	}
}

// `Tonemap.NONE`. Not a no-op: see that enum value's own doc comment
// (lighting.odin) for why clamping to [0, 1] here, rather than leaving it to
// whatever the destination format does on write, is what makes NONE and
// every other curve hand `tonemap_encode` the same range to work with.
@(private)
tonemap_none :: proc(color: [3]f32) -> [3]f32 {
	return {
		clamp(color.x, 0, 1),
		clamp(color.y, 0, 1),
		clamp(color.z, 0, 1),
	}
}

@(private)
tonemap_reinhard :: proc(color: [3]f32) -> [3]f32 {
	return {
		color.x / (1 + color.x),
		color.y / (1 + color.y),
		color.z / (1 + color.z),
	}
}

@(private)
tonemap_aces_channel :: proc(x: f32) -> f32 {
	a :: f32(2.51)
	b :: f32(0.03)
	c :: f32(2.43)
	d :: f32(0.59)
	e :: f32(0.14)

	return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0, 1)
}

// Narkowicz's fit to the ACES filmic reference curve -- the three-line
// version nearly every engine that calls its own tonemap "ACES" actually
// means, not the real RRT+ODT, which is a 3D LUT and not three multiply-adds.
@(private)
tonemap_aces :: proc(color: [3]f32) -> [3]f32 {
	return {
		tonemap_aces_channel(color.x),
		tonemap_aces_channel(color.y),
		tonemap_aces_channel(color.z),
	}
}

/*
	The per-channel half of a minimal AgX: log2-encode into Sobotka's own
	[-12.47393, 4.026069] EV window, normalize to [0, 1], then a 6th-order
	polynomial fit to AgX's own default contrast sigmoid (mean error ~3.67e-6
	against the reference in the fit this was taken from). Takes one already-
	mixed channel -- see `tonemap_agx` for the matrix step this cannot do,
	since it mixes the three.
*/
@(private)
tonemap_agx_channel :: proc(x: f32) -> f32 {
	min_ev :: f32(-12.47393)
	max_ev :: f32(4.026069)

	// The epsilon floor is not the "physically nothing is below it" clamp
	// tonemap_expose already applied -- it exists so log2 never sees exactly
	// zero. HLSL's log2(0) and Odin's math.log2(0) both produce -Inf and
	// clamping -Inf against min_ev is well-defined either way, but relying on
	// the two languages' IEEE edge-case behaviour staying identical is a
	// portability bet this file does not need to make when a floor this far
	// below min_ev changes nothing the clamp does not already decide.
	v := math.log2(max(x, 1e-10))
	v = clamp(v, min_ev, max_ev)
	v = (v - min_ev) / (max_ev - min_ev)

	v2 := v * v
	v4 := v2 * v2
	v = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v - 0.00232

	return clamp(v, 0, 1)
}

/*
	A minimal approximation of Troy Sobotka's AgX: the inset matrix and the
	log2/contrast pipeline (`tonemap_agx_channel`) only. Deliberately not the
	rest of a full AgX implementation -- there is no outset matrix undoing the
	inset's colour-space narrowing, and the result here is handed to the same
	1/2.2 `tonemap_encode` every other curve uses rather than AgX's own
	display transform. A colour-managed AgX would want both; this is P1's
	scaffolding for "a fourth curve exists and is selectable", not a
	colorimetrically faithful port, and a later phase that wants the real
	thing has a known, stated gap to close rather than a silent one.

	The matrix is three explicit dot products rather than a `matrix[3,3]f32`
	multiply, so this and `shaders/tonemap.frag.hlsl`'s own `tonemap_agx`
	cannot silently disagree on which is being multiplied -- HLSL's default
	row-major storage and Odin's array-of-arrays matrix layout are not the
	same convention, and a transposed 3x3 constant is a wrong-looking-sky
	kind of bug (`skybox_cubemap.frag.hlsl`'s own left-handed sampling comment
	is the same lesson learned once already) rather than one that fails to
	compile.
*/
@(private)
tonemap_agx :: proc(color: [3]f32) -> [3]f32 {
	r := 0.842479062253094 * color.x + 0.0784335999999992 * color.y + 0.0792237451477643 * color.z
	g := 0.0423282422610123 * color.x + 0.878468636469772 * color.y + 0.0791661274605434 * color.z
	b := 0.0423756549057051 * color.x + 0.0784336 * color.y + 0.879142973793104 * color.z

	return {
		tonemap_agx_channel(r),
		tonemap_agx_channel(g),
		tonemap_agx_channel(b),
	}
}

// The shared final step, after whichever curve ran. 1/2.2 rather than the
// real sRGB piecewise transfer function -- the same simplification
// `shade_surface` (lighting_core.hlsli) used to apply inline before this
// phase moved it here, kept because every colour already in this package was
// tuned against that constant rather than the real curve.
@(private)
tonemap_encode :: proc(color: [3]f32) -> [3]f32 {
	return {
		math.pow(color.x, 1.0 / 2.2),
		math.pow(color.y, 1.0 / 2.2),
		math.pow(color.z, 1.0 / 2.2),
	}
}

// The whole resolve, CPU side: exposure, the curve `tonemap` selects, then
// the shared encode -- mirrors `shaders/tonemap.frag.hlsl`'s `main`
// statement for statement. Not called by `resolve_tonemap` itself, which
// pushes the raw settings to the GPU and lets the shader run this same
// arithmetic; this exists so `tonemap_test.odin` has something to call.
@(private)
tonemap_apply :: proc(color: [3]f32, exposure: f32, tonemap: Tonemap) -> [3]f32 {
	c := tonemap_expose(color, exposure)

	switch tonemap {
	case .NONE:     c = tonemap_none(c)
	case .REINHARD: c = tonemap_reinhard(c)
	case .ACES:     c = tonemap_aces(c)
	case .AGX:      c = tonemap_agx(c)
	}

	return tonemap_encode(c)
}
