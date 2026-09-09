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

	**Not a real GPU cube texture.** The obvious shape -- one `sdl.GPUTexture`
	of `type = .CUBE`, rendered into face by face -- does not exist in
	SDL_GPU's own API: `GPUDepthStencilTargetInfo` (the struct
	`BeginGPURenderPass` takes for its depth attachment) has no `layer_or_
	depth_plane` field at all, unlike `GPUColorTargetInfo`, which does. A
	colour target can be told which layer or cube face to render into; a
	depth-stencil target cannot be pointed at anything but layer/face 0 of
	whatever texture it names. This is a real, checked limitation of the
	vendor binding this package builds against (`vendor:sdl3`'s
	`sdl3_gpu.odin`), not an assumption -- see this phase's own report for
	where it was confirmed. So each face is its own full `D2` depth texture,
	the exact same shape `shadow_standard.odin`'s two maps already are, and
	`cube_textures[caster]` is `[6]^sdl.GPUTexture` rather than one texture of
	six layers.

	A consequence worth stating plainly: this makes a point-light shadow six
	times the render cost of a directional or spot one (six passes over
	whatever casts it, instead of one), and the six maps are sampled in the
	fragment shader as six separate `Texture2D`s rather than one filtered
	`TextureCube` -- there is no hardware seam-blending between them, so a
	fragment near a cube face's edge samples only its own face's map with no
	averaging against its neighbour. A real `TextureCube` could be built by
	rendering each face into its own `D2` texture as here and then copying
	each into a layer of a combined `CUBE`-type sampled texture with
	`CopyGPUTextureToTexture` (which *does* support per-layer addressing, via
	`GPUTextureRegion.layer`, unlike the render-target path) -- but there is
	no GPU capture tooling in this environment to confirm SDL_GPU accepts a
	depth-format texture-to-texture copy, and building a second, unverifiable
	assumption on top of an already-unverified rendering path was judged the
	worse trade. Six flat `Texture2D`s is the option built entirely out of
	patterns this package has already proven work (`shadow_map0`/`shadow_map1`
	are exactly this shape). Revisit if seam artifacts turn out to matter more
	than this phase's own inability to see them render did.

	**Face selection is this file's own convention, not a standard cubemap
	layout.** Nothing here samples hardware cube-map addressing, so there is
	no existing convention to match -- `shadow_cube_face_direction` and
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
	Builds `MAX_POINT_SHADOW_CASTERS * 6` real shadow maps at
	`settings.resolution`, only when `settings.enabled` and only when turning
	them on for the first time or the resolution changed -- see
	`apply_standard_shadow_textures`'s own doc comment (shadow_standard.odin)
	for why an unrelated setting changing must not rebuild these every call.

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
	if s.cube_resolution == i32(size) && s.cube_textures[0][0] != nil {
		return // already built at this resolution -- nothing to do
	}

	new_textures: [MAX_POINT_SHADOW_CASTERS][6]^sdl.GPUTexture
	for caster in 0 ..< MAX_POINT_SHADOW_CASTERS {
		for face in 0 ..< 6 {
			new_textures[caster][face] = sdl.CreateGPUTexture(r.device, {
				type                 = .D2,
				format               = s.format,
				usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
				width                = u32(size),
				height               = u32(size),
				layer_count_or_depth = 1,
				num_levels           = 1,
			})

			if new_textures[caster][face] == nil {
				log.errorf("could not create a cube shadow map: %s", sdl.GetError())
				s.settings.enabled = false

				for c2 in 0 ..< MAX_POINT_SHADOW_CASTERS {
					for f in 0 ..< 6 {
						if new_textures[c2][f] != nil {
							sdl.ReleaseGPUTexture(r.device, new_textures[c2][f])
						}
					}
				}
				return
			}
		}
	}

	for caster in 0 ..< MAX_POINT_SHADOW_CASTERS {
		for face in 0 ..< 6 {
			if s.cube_textures[caster][face] != nil {
				sdl.ReleaseGPUTexture(r.device, s.cube_textures[caster][face])
			}
			s.cube_textures[caster][face] = new_textures[caster][face]
		}
	}

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
		if face == 0 && !s.warned {
			log.warn("begin_point_shadow_pass: shadows are not enabled, or no point light is marked casts_shadow -- skipped")
			s.warned = true
		}
		return false
	}
	if face == 0 do s.warned = false

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

	depth := sdl.GPUDepthStencilTargetInfo{
		texture          = s.cube_textures[0][face],
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
