package matchbox

/*
	Cascaded shadow maps
	---------------------
	Splits a directional caster's frustum into `Shadow_Settings.cascade_count`
	slices along the *camera's* own view depth, fits a tight orthographic box
	around each slice as seen from the light, and renders one map per slice.
	The near cascade ends up with a texel a fraction the size of a single map
	covering the whole camera frustum -- which is CSM's actual point: the
	acne and aliasing `shadow_test.odin` measures are worst wherever the
	texel is biggest, and a single far-reaching map hands its worst texel to
	the nearest, most scrutinised geometry in the whole scene.

	**Directional only, in any useful sense.** A spot light already has a
	bounded cone -- cascading it buys nothing a single, tighter map does not
	already give for free. A spot caster routed through `Shadow_Settings{
	technique = .CASCADED}` still works structurally (every cascade collapses
	to the same single-map frustum `begin_shadow_pass`'s own spot branch
	already builds, since the split range comes from the camera rather than
	the light), it is just a wasted `cascade_count`-fold multiplication of
	render passes for an identical picture. Not guarded against, the same
	"an unsupported combination degrades rather than errors" shape the rest
	of this package already has -- a game has no reason to pick CASCADED for
	a spot caster in the first place.

	**Where this strains the four-place contract.** `lighting_rework.md`
	section 2's modularity test is "a `.hlsli`, an enum value, one `#include`,
	one dispatcher line, plus whatever CPU-side pass setup its own file
	needs" -- and CSM is the first technique that needs a *second* uniform
	block (`Cascade_Frag_Data`, lighting.odin) beyond the two sampler slots
	`PCF`/`PCSS` already have, neither of which the P0/P2 contract
	anticipated. Both are additive: `mesh.frag.hlsl` gains a declaration and a
	bind call, `push_lighting` gains a second push, and
	`shadow_visibility_cascaded` (shaders/shadow/cascaded.hlsli) is the only
	place any of it is read. Nothing in `sample_light`, `Light_Sample`,
	`Radiance`, `Surface` or any shading-model `.hlsli` file changed to make room for
	it -- the strain landed exactly where the brief said to look for it
	(register/uniform-block plumbing), not in the shared shading contract.

	**One Texture2DArray, not `MAX_SHADOW_CASTERS * MAX_CASCADES` separate
	textures, since P3b.** P3 built one `D2` texture per (caster, cascade)
	pair on the mistaken belief that `GPUDepthStencilTargetInfo` could not
	target a single layer of a larger texture -- see `shadow.odin`'s own doc
	comment on `Shadow_State` for the correction and where the field actually
	lives. `apply_cascade_shadow_textures` below now builds one
	`D2_ARRAY` texture with `MAX_SHADOW_CASTERS * MAX_CASCADES` layers, and
	`begin_cascade_shadow_pass` points each pass at its own layer via
	`GPUDepthStencilTargetInfo.layer` rather than at its own texture. The
	fragment shader samples the result through one `Texture2DArray` binding
	(`cascade_maps`/`cascade_sampler`, mesh.frag.hlsl) instead of an
	eight-element resource array -- see `shaders/shadow/cascaded.hlsli`'s own
	top comment.
*/

import "core:log"
import "core:math"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	Splits `[near, far]` into up to `MAX_CASCADES` sub-ranges, each entry
	being that cascade's own far edge (its near edge is the previous entry's
	far edge, or `near` itself for cascade 0) -- the "practical split scheme"
	most real-time renderers use: a `lambda` blend of a uniform split (every
	cascade the same depth range) and a logarithmic one (every cascade closer
	to the same *projected* footprint, since perspective already compresses
	distant depth into fewer screen pixels on its own). `lambda = 0` is pure
	uniform, `1` pure logarithmic; `SHADOW_DEFAULTS.cascade_split_lambda`
	(0.5) is the usual middle ground between "the far cascade is enormous"
	and "the near cascade is razor-thin".

	Entries at or past `count` are left at `far` rather than zero, so a caller
	indexing the fixed-size result without checking `count` first reads a
	harmless degenerate (zero-depth) cascade at `far` rather than one that
	spans backwards from `far` to 0.

	Pulled out of `begin_cascade_shadow_pass` so `shadow_test.odin` can check
	it directly against independently worked-out splits rather than only
	through the much harder-to-inspect view-projection matrices it feeds.
*/
compute_cascade_splits :: proc(near, far: f32, count: int, lambda: f32) -> [MAX_CASCADES]f32 {
	splits: [MAX_CASCADES]f32
	n := clamp(count, 1, MAX_CASCADES)

	for i in 0 ..< n {
		p             := f32(i + 1) / f32(n)
		log_split     := near * math.pow(far / near, p)
		uniform_split := near + (far - near) * p
		splits[i] = lambda * log_split + (1 - lambda) * uniform_split
	}
	for i in n ..< MAX_CASCADES {
		splits[i] = far
	}

	return splits
}

/*
	The view-projection for one cascade: fits a tight orthographic box, in
	light space, around the camera's own frustum slice between `split_near`
	and `split_far` (both view-space depths along the camera's forward axis).

	The eight corners of that frustum slice are worked out in world space
	from the camera's inverse view matrix and its own fov/aspect (the same
	numbers `camera3d_projection` derives its perspective matrix from), then
	transformed into light space and bounded -- the box that comes out is
	exactly as tight as it can be for this slice, which is the whole reason
	to compute it per cascade instead of reusing one frustum-sized box for
	all of them the way `begin_shadow_pass`'s own directional branch does.

	Pulled out of `begin_cascade_shadow_pass` for the same testability reason
	`compute_cascade_splits` is -- `shadow_test.odin` checks specific,
	independently-derived cases (a camera looking straight down its own axis,
	a light straight overhead) against this function directly.
*/
@(private)
compute_cascade_view_projection :: proc(
	camera: Camera3D, light_direction: [3]f32, split_near, split_far: f32,
) -> matrix[4, 4]f32 {
	c        := camera3d_defaults(camera)
	view     := camera3d_view(c)
	inv_view := linalg.matrix4_inverse(view)

	width  := f32(mbi.window_width)
	height := f32(mbi.window_height)
	aspect: f32 = 1
	if height > 0 do aspect = width / height

	tan_half := math.tan(math.to_radians(c.fov) * 0.5)

	corners: [8][3]f32
	i := 0
	for depth in ([]f32{split_near, split_far}) {
		h := tan_half * depth
		w := h * aspect
		for sy in ([]f32{-1, 1}) {
			for sx in ([]f32{-1, 1}) {
				view_space := [4]f32{sx * w, sy * h, -depth, 1}
				world      := inv_view * view_space
				corners[i]  = world.xyz
				i += 1
			}
		}
	}

	center := [3]f32{0, 0, 0}
	for corner in corners do center += corner
	center *= 1.0 / 8.0

	light_dir := linalg.normalize(light_direction)
	up        := [3]f32{0, 1, 0}
	if abs(linalg.dot(light_dir, up)) > 0.99 {
		up = {0, 0, 1}
	}

	// Pulled back further than any corner could possibly be -- refined into
	// a tight near/far below rather than guessed at, so this only has to be
	// "far enough for every corner to land in front of the eye", not exact.
	eye := center - light_dir * (split_far - split_near + far_enough_margin(camera))

	light_view := look_at_matrix(eye, center, up)

	low, high: [3]f32 = {max(f32), max(f32), max(f32)}, {-max(f32), -max(f32), -max(f32)}
	for corner in corners {
		p := light_view * [4]f32{corner.x, corner.y, corner.z, 1}
		low.x  = min(low.x, p.x);  high.x = max(high.x, p.x)
		low.y  = min(low.y, p.y);  high.y = max(high.y, p.y)
		low.z  = min(low.z, p.z);  high.z = max(high.z, p.z)
	}

	// look_at_matrix looks down -z, so a corner in front of the eye has a
	// negative light-space z; ortho()'s near/far both want positive distance
	// along the view axis, hence the sign flip and the swap of which bound
	// becomes which.
	ortho_near := -high.z
	ortho_far  := -low.z

	return ortho(low.x, high.x, low.y, high.y, ortho_near, ortho_far) * light_view
}

// How far back to pull the light-space eye before measuring corners --
// bigger than the camera's own far plane guarantees every frustum corner
// (which is, at most, that far from the camera) lands in front of it.
@(private)
far_enough_margin :: proc(camera: Camera3D) -> f32 {
	c := camera3d_defaults(camera)
	return c.far + 100
}

/*
	Builds one `MAX_SHADOW_CASTERS * MAX_CASCADES`-layer shadow map array at
	`settings.resolution`, only when `settings.technique` is `CASCADED` and
	only when turning it on for the first time or the resolution changed --
	see `apply_standard_shadow_textures`'s own doc comment (shadow_standard.odin)
	for why an unrelated setting changing must not rebuild this every call.

	One `CreateGPUTexture` call rather than `MAX_SHADOW_CASTERS * MAX_CASCADES`
	of them, since P3b -- see `shadow.odin`'s own doc comment on
	`Shadow_State` for why a layered array replaced one texture per layer.
*/
@(private)
apply_cascade_shadow_textures :: proc(settings: Shadow_Settings) {
	r := &mbi.renderer
	s := &r.lighting.shadow

	if settings.technique != .CASCADED do return

	size := max(settings.resolution, 1)
	if s.cascade_resolution == i32(size) && s.cascade_texture != nil {
		return // already built at this resolution -- nothing to do
	}

	new_texture := sdl.CreateGPUTexture(r.device, {
		type                 = .D2_ARRAY,
		format               = s.format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = u32(size),
		height               = u32(size),
		layer_count_or_depth = MAX_SHADOW_CASTERS * MAX_CASCADES,
		num_levels           = 1,
	})

	if new_texture == nil {
		log.errorf("could not create the cascade shadow map array: %s", sdl.GetError())
		s.settings.enabled = false
		return
	}

	if s.cascade_texture != nil {
		sdl.ReleaseGPUTexture(r.device, s.cascade_texture)
	}
	s.cascade_texture = new_texture

	s.cascade_resolution = i32(size)
}

/*
	Opens the shadow pass for `slot`'s `cascade`-th map (0 up to
	`Shadow_Settings.cascade_count`, not inclusive). The `CASCADED` counterpart of `begin_shadow_pass`
	(shadow_standard.odin) -- see that procedure's own doc comment for the
	shared parts of this contract (the return value, the per-slot warning,
	the "opt in twice" requirement).

	All of a slot's cascades' splits and view-projections are (re)computed
	together, the first time this is called for that slot each frame
	(`cascade == 0`) -- cheap (at most `MAX_CASCADES` matrix builds) next to
	a whole shadow pass, and it means a caller that draws cascade 2 before
	cascade 0 for some reason still reads a fresh matrix rather than a stale
	one from whichever frame last visited cascade 0.
*/
begin_cascade_shadow_pass :: proc(slot: int, cascade: int) -> bool {
	r := &mbi.renderer
	s := &r.lighting.shadow

	if !r.frame_active do return false
	if slot < 0 || slot >= MAX_SHADOW_CASTERS do return false
	if cascade < 0 || cascade >= MAX_CASCADES do return false

	count := clamp(s.settings.cascade_count, 1, MAX_CASCADES)
	if cascade >= count do return false

	if !s.settings.enabled || s.caster_indices[slot] < 0 {
		if slot == 0 && cascade == 0 && !s.warned_cascade {
			log.warn("begin_cascade_shadow_pass: shadows are not enabled, or no light is marked casts_shadow -- skipped")
			s.warned_cascade = true
		}
		return false
	}
	if slot == 0 && cascade == 0 do s.warned_cascade = false

	caster := r.lighting.light_data[s.caster_indices[slot]]

	// See this file's own top comment: a spot caster still works here, it
	// just gets `count` identical cascades since the split range comes from
	// the camera rather than the light's own cone.
	is_spot         := caster.target.w > 1.5
	light_direction := linalg.normalize(caster.target.xyz) if is_spot else linalg.normalize(caster.target.xyz - caster.position.xyz)

	if cascade == 0 {
		camera_defaults := camera3d_defaults(r.camera3d)
		split_near := camera_defaults.near
		split_far  := min(camera_defaults.far, s.settings.far)

		s.cascade_splits = compute_cascade_splits(split_near, split_far, count, s.settings.cascade_split_lambda)

		lo := split_near
		for c in 0 ..< count {
			hi := s.cascade_splits[c]
			s.cascade_view_projections[slot][c] = compute_cascade_view_projection(r.camera3d, light_direction, lo, hi)
			lo = hi
		}
	}

	s.active_slot    = slot
	s.active_cascade = cascade
	s.active_kind    = .CASCADE

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// `layer`, not a separate texture per (slot, cascade) pair -- see
	// shadow.odin's own doc comment on Shadow_State for why. Caster-major,
	// the same flattening cascade_view_projection reads on the shader side
	// (shaders/shadow/cascaded.hlsli).
	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = s.cascade_texture,
		layer            = u8(slot * MAX_CASCADES + cascade),
		clear_depth      = 1,
		load_op          = .CLEAR,
		store_op         = .STORE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}

	r.pass = sdl.BeginGPURenderPass(r.cmd, nil, 0, &depth)
	if r.pass == nil do return false

	bind_cache_reset()

	r.in_shadow_pass = true
	return true
}
