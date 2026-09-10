package matchbox

/*
	Cube shadow maps
	-----------------
	A point light radiates in every direction, not down one axis or into one
	cone, so one depth-from-light-view map (what `PCF`/`PCSS`/`CASCADED` all
	build) cannot describe its shadow at all -- there is no single view to
	render it from. This is the "a point light cannot cast a shadow" degrade
	`shadow.odin` documented from P0 onward, and this file is what removes it:
	six views, one per cube face, each its own ordinary shadow map.

	**One layered Texture2DArray, not six separate textures -- and not a real
	depth TextureCube either, since P3b.** P3's own account of this said
	`GPUDepthStencilTargetInfo` had no field for targeting one layer or face
	of a larger texture at all, unlike `GPUColorTargetInfo`'s
	`layer_or_depth_plane`. That premise was false: the struct has `layer:
	Uint8` as its last field (`vendor/sdl3/sdl3_gpu.odin`), confirmed by
	reading the struct directly rather than by trusting the comment this one
	replaces -- see `lighting_rework.md` section 7.7. So a single texture with
	six layers, one face per layer, is exactly as renderable-into as six
	separate ones: `begin_point_shadow_pass` below now points each pass at
	`cube_texture`'s own `face`-th layer via that field.

	What remains a real, load-bearing choice is `D2_ARRAY` over a genuine
	`CUBE`-type depth texture. SDL_GPU's `GPUTextureType` does have `.CUBE`,
	and `GPUTextureCreateInfo` would accept `usage = {.DEPTH_STENCIL_TARGET,
	.SAMPLER}` on one syntactically -- but there is no GPU in this environment
	to confirm every backend actually creates a depth-format cube texture
	with both of those usage flags set, and the array shape sidesteps the
	question entirely while still collapsing the sampler count exactly as
	much: `shadow_cube_face_index` below already resolves a direction to a
	face number, so indexing a `Texture2DArray` by that same number costs
	nothing a real cube texture's hardware seam-blending would have bought
	back. If a future phase confirms a depth `TextureCube` works everywhere
	this package targets, revisiting this trades the array for one that
	blends across face edges; nothing else about the pass or bias code
	changes either way, since neither this file nor the shader currently
	relies on hardware cube addressing.

	**Face selection is this file's own convention, not a standard cubemap
	layout.** Unchanged from P3: nothing here samples hardware cube-map
	addressing, so there is no existing convention to match --
	`shadow_cube_face_direction` and
	`shadow_cube_face_index` only have to agree with *each other* (and with
	`shaders/shadow/cube.hlsli`'s own mirror of the second one), not with
	OpenGL's or Direct3D's own face order.
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	Face `face`'s own look direction and up vector, in world space, for a
	point light at any position -- the six together tile the whole sphere
	once each is given a 90-degree field of view. `up` is never parallel to
	`direction` for any of the six (checked by inspection: every pair here is
	orthogonal), so unlike `begin_shadow_pass`'s directional branch, this
	needs no fallback for the degenerate case.
*/
@(private)
shadow_cube_face_direction :: proc(face: int) -> (direction, up: [3]f32) {
	switch face {
	case 0: return {1, 0, 0}, {0, 1, 0}
	case 1: return {-1, 0, 0}, {0, 1, 0}
	case 2: return {0, 1, 0}, {0, 0, -1}
	case 3: return {0, -1, 0}, {0, 0, 1}
	case 4: return {0, 0, 1}, {0, 1, 0}
	case 5: return {0, 0, -1}, {0, 1, 0}
	}
	return {0, 0, 1}, {0, 1, 0}
}

/*
	Which of the six faces built by `shadow_cube_face_direction` a direction
	away from the light falls into -- the ordinary major-axis cubemap face
	test (whichever axis has the largest magnitude component picks the pair,
	that component's sign picks which of the pair), mirrored exactly in
	`shaders/shadow/cube.hlsli`'s own `shadow_cube_face_index`. The two must
	agree on which face wins a tie (`>=`, consistently, checked in the same
	x-then-y-then-z order on both sides) or a fragment would sample a
	different face than the one its own depth was ever rendered into --
	`shadow_test.odin` checks this function directly against directions
	placed exactly on and near each face's own boundary for that reason.
*/
shadow_cube_face_index :: proc(direction: [3]f32) -> int {
	ax, ay, az := abs(direction.x), abs(direction.y), abs(direction.z)
	switch {
	case ax >= ay && ax >= az: return 0 if direction.x > 0 else 1
	case ay >= ax && ay >= az: return 2 if direction.y > 0 else 3
	case:                      return 4 if direction.z > 0 else 5
	}
}

/*
	Builds one `MAX_POINT_SHADOW_CASTERS * 6`-layer shadow map array at
	`settings.resolution`, only when `settings.enabled` and only when turning
	it on for the first time or the resolution changed -- see
	`apply_standard_shadow_textures`'s own doc comment (shadow_standard.odin)
	for why an unrelated setting changing must not rebuild this every call.

	One `CreateGPUTexture` call rather than `MAX_POINT_SHADOW_CASTERS * 6` of
	them, since P3b -- see this file's own top comment and `shadow.odin`'s own
	doc comment on `Shadow_State` for why a layered array replaced one
	texture per face.

	Unlike the other two groups, this one is **not** gated on
	`settings.technique` -- see `Shadow_Technique`'s own doc comment for why
	cube shadows run independently of whichever of `PCF`/`PCSS`/`CASCADED` the
	scene's directional/spot casters are using.
*/
@(private)
apply_cube_shadow_textures :: proc(settings: Shadow_Settings) {
	r := &mbi.renderer
	s := &r.lighting.shadow

	size := max(settings.resolution, 1)
	if s.cube_resolution == i32(size) && s.cube_texture != nil {
		return // already built at this resolution -- nothing to do
	}

	new_texture := sdl.CreateGPUTexture(r.device, {
		type                 = .D2_ARRAY,
		format               = s.format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = u32(size),
		height               = u32(size),
		layer_count_or_depth = MAX_POINT_SHADOW_CASTERS * 6,
		num_levels           = 1,
	})

	if new_texture == nil {
		log.errorf("could not create the cube shadow map array: %s", sdl.GetError())
		s.settings.enabled = false
		return
	}

	if s.cube_texture != nil {
		sdl.ReleaseGPUTexture(r.device, s.cube_texture)
	}
	s.cube_texture = new_texture

	s.cube_resolution = i32(size)
}

/*
	Opens the shadow pass for the single point-light caster's `face`-th map
	(0..5, `shadow_cube_face_direction`'s own order). The `CUBE` counterpart
	of `begin_shadow_pass` (shadow_standard.odin) -- see that procedure's own
	doc comment for the shared parts of this contract.

	All six of the caster's own view-projections are (re)computed together,
	the first time this is called each frame (`face == 0`) -- the same
	"compute the whole group once, reuse it for the rest of this frame's
	calls into it" shape `begin_cascade_shadow_pass` uses for its own splits.

	No `slot`/`caster` parameter: `MAX_POINT_SHADOW_CASTERS` is 1, so there is
	only ever the one to name -- see that constant's own doc comment
	(shadow.odin) for why.
*/
begin_point_shadow_pass :: proc(face: int) -> bool {
	r := &mbi.renderer
	s := &r.lighting.shadow

	if !r.frame_active do return false
	if face < 0 || face >= 6 do return false

	caster_index := s.cube_caster_index[0]

	if !s.settings.enabled || caster_index < 0 {
		if face == 0 && !s.warned_cube {
			log.warn("begin_point_shadow_pass: shadows are not enabled, or no point light is marked casts_shadow -- skipped")
			s.warned_cube = true
		}
		return false
	}
	if face == 0 do s.warned_cube = false

	light_position := r.lighting.light_data[caster_index].position.xyz

	if face == 0 {
		for f in 0 ..< 6 {
			direction, up := shadow_cube_face_direction(f)
			view := look_at_matrix(light_position, light_position + direction, up)
			// 90 degrees exactly tiles a cube face with no overlap and no
			// gap; aspect 1, since every face's own map is square.
			proj := perspective(90, 1, s.settings.near, s.settings.far)
			s.cube_view_projections[0][f] = proj * view
		}
	}

	s.active_face = face
	s.active_kind = .CUBE

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// `layer`, not a separate texture per face -- see this file's own top
	// comment and shadow.odin's own doc comment on Shadow_State for why.
	// MAX_POINT_SHADOW_CASTERS is 1, so `face` alone names the layer with no
	// caster term to add.
	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = s.cube_texture,
		layer            = u8(face),
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
