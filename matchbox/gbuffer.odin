package matchbox

/*
	G-buffer
	--------
	The deferred pipeline's own render targets, and a CPU mirror of the pack
	shaders/gbuffer.hlsli's `gbuffer_encode`/`gbuffer_decode` do -- see that
	file's own top comment for the layout (four `R16G16B16A16_FLOAT`
	targets, one `Surface` field group packed into each) and for why a
	`Surface` field is never split across two shading models' own use of the
	same four "param" floats.

	The GPU-facing half (`Gbuffer_Targets`, `ensure_gbuffer_targets`) is real
	code, called every frame `DEFERRED` is active. The CPU mirror below it
	(`gbuffer_encode`/`gbuffer_decode`/`gbuffer_encode_normal`/
	`gbuffer_decode_normal`) is not called by anything at runtime -- it
	exists so `gbuffer_test.odin` has something to call, the same shape
	`tonemap_apply` (tonemap.odin) already has for the tonemap curves: there
	is no GPU in this environment to run the real shader and read its
	output back, so the packing is proven correct by an independently
	written twin instead, checked against known values and swept for its
	own worst case.
*/

import "core:log"
import "core:math"
import "core:math/linalg"

import sdl "vendor:sdl3"

// -----------------------------------------------------------------------
// GPU-facing
// -----------------------------------------------------------------------

/*
	The four fill targets and the pass's own depth texture -- see
	`shaders/gbuffer.hlsli`'s own top comment for what each of GB_A..GB_D
	carries.

	**A dedicated depth texture, not `Renderer.depth_texture`.** The
	deferred lighting pass has to *sample* this depth (position
	reconstruction, `deferred_lighting.frag.hlsl`) as well as have it
	written as a depth-stencil target during the fill pass -- the identical
	"written as a depth target and also sampled as a texture" combination
	`Shadow_State.format` (shadow.odin) already exists to solve, and
	`pick_depth_format` (render3d.odin) was never asked to guarantee: its
	own candidate order prefers `D24_UNORM_S8_UINT` first for reasons that
	have nothing to do with sampling it back, and `pick_shadow_format`'s own
	doc comment already flags that exact format as "the more likely of the
	three to refuse" a sampled combination. Reusing `pick_shadow_format`
	here rather than widening `Renderer.depth_texture`'s own usage flags
	keeps every forward/clustered game's depth texture exactly as it was --
	this is a second, independent texture that exists only once a game
	selects `DEFERRED`, at the cost of one more format query and one more
	texture, not a change to a resource every game already depends on.
*/
Gbuffer_Targets :: struct {
	a, b, c, d: ^sdl.GPUTexture,
	depth:      ^sdl.GPUTexture,

	format:       sdl.GPUTextureFormat, // shared by a/b/c/d
	depth_format: sdl.GPUTextureFormat,

	width, height: i32,
}

// The format every G-buffer colour target is created in -- `R16G16B16A16_FLOAT`,
// the identical reasoning `pick_hdr_format` (tonemap.odin) already gives for
// the HDR scene target: every backend this package targets guarantees it for
// a sampled colour target, so there is no fallback list to build the way
// `pick_depth_format`/`pick_shadow_format` need one for formats that
// genuinely vary by driver.
@(private)
pick_gbuffer_format :: proc() -> sdl.GPUTextureFormat {
	if sdl.GPUTextureSupportsFormat(mbi.renderer.device, .R16G16B16A16_FLOAT, .D2, {.COLOR_TARGET, .SAMPLER}) {
		return .R16G16B16A16_FLOAT
	}

	log.error("this device does not support a floating-point colour target; the deferred pipeline will not work")
	return .R16G16B16A16_FLOAT
}

/*
	Makes sure the four G-buffer targets and their own depth texture exist
	and match whatever destination `begin_drawing_3d` is rendering into this
	frame -- the same "recreate rather than resize" shape `ensure_hdr_texture`
	(tonemap.odin) and `ensure_depth_texture` (render3d.odin) already have,
	for the identical reason: a GPU texture has no resize.

	Only called once `Lighting_Settings.pipeline == .DEFERRED`
	(`pipeline_deferred_begin`) -- a game that never selects `DEFERRED` never
	allocates any of this, the same "pay only for what you use" shape the
	depth texture and the HDR target already have for 3D itself.
*/
@(private)
ensure_gbuffer_targets :: proc() -> bool {
	r := &mbi.renderer
	if r.device == nil do return false

	size := get_current_target_size()
	width, height := i32(size.x), i32(size.y)
	if width <= 0 || height <= 0 do return false

	g := &r.lighting.gbuffer
	if g.a != nil && g.width == width && g.height == height {
		return true
	}

	if g.a != nil do sdl.ReleaseGPUTexture(r.device, g.a)
	if g.b != nil do sdl.ReleaseGPUTexture(r.device, g.b)
	if g.c != nil do sdl.ReleaseGPUTexture(r.device, g.c)
	if g.d != nil do sdl.ReleaseGPUTexture(r.device, g.d)
	if g.depth != nil do sdl.ReleaseGPUTexture(r.device, g.depth)
	g.a, g.b, g.c, g.d, g.depth = nil, nil, nil, nil, nil

	if g.format == .INVALID do g.format = pick_gbuffer_format()
	if g.depth_format == .INVALID do g.depth_format = pick_shadow_format()

	targets: [4]^sdl.GPUTexture
	ok := true
	for i in 0 ..< 4 {
		targets[i] = sdl.CreateGPUTexture(r.device, {
			type                 = .D2,
			format               = g.format,
			usage                = {.COLOR_TARGET, .SAMPLER},
			width                = u32(width),
			height               = u32(height),
			layer_count_or_depth = 1,
			num_levels           = 1,
		})
		ok &= targets[i] != nil
	}
	g.a, g.b, g.c, g.d = targets[0], targets[1], targets[2], targets[3]

	g.depth = sdl.CreateGPUTexture(r.device, {
		type                 = .D2,
		format               = g.depth_format,
		usage                = {.DEPTH_STENCIL_TARGET, .SAMPLER},
		width                = u32(width),
		height               = u32(height),
		layer_count_or_depth = 1,
		num_levels           = 1,
	})
	ok &= g.depth != nil

	if !ok {
		log.errorf("could not create the G-buffer targets: %s", sdl.GetError())
		return false
	}

	g.width, g.height = width, height
	return true
}

// -----------------------------------------------------------------------
// CPU mirror -- see this file's own top comment
// -----------------------------------------------------------------------

// GB_B's own sentinel for "no geometry was ever drawn into this pixel" --
// mirrors `GBUFFER_EMPTY` (shaders/gbuffer.hlsli) exactly; see that file's
// own top comment for the discard it drives in the lighting pass.
GBUFFER_EMPTY :: f32(-1.0)

/*
	Octahedral normal encoding, mirroring `gbuffer_encode_normal`
	(shaders/gbuffer.hlsli) statement for statement -- see that function's
	own doc comment for the method and the citation. Odin has no built-in
	`sign` returning ±1 at exactly zero the way this needs (`math.sign`
	returns 0 at 0, which would zero out the fold at the octahedron's own
	seams), so the same explicit `>= 0 ? 1 : -1` the HLSL uses is written
	out here too rather than reached for from `core:math`.
*/
@(private)
gbuffer_encode_normal :: proc(n: [3]f32) -> [2]f32 {
	l1 := abs(n.x) + abs(n.y) + abs(n.z)
	p3 := [3]f32{n.x, n.y, n.z} / max(l1, 1e-8)
	p := [2]f32{p3.x, p3.y}

	if p3.z < 0 {
		sign_x: f32 = 1 if p.x >= 0 else -1
		sign_y: f32 = 1 if p.y >= 0 else -1
		p = {(1 - abs(p.y)) * sign_x, (1 - abs(p.x)) * sign_y}
	}

	return p
}

// Mirrors `gbuffer_decode_normal` (shaders/gbuffer.hlsli) statement for
// statement.
@(private)
gbuffer_decode_normal :: proc(p: [2]f32) -> [3]f32 {
	n := [3]f32{p.x, p.y, 1 - abs(p.x) - abs(p.y)}

	t: f32 = clamp(-n.z, 0, 1)
	sign_x: f32 = 1 if n.x >= 0 else -1
	sign_y: f32 = 1 if n.y >= 0 else -1
	n.x -= t * sign_x
	n.y -= t * sign_y

	return linalg.normalize(n)
}

/*
	Mirror of `Surface` (surface.hlsli), restricted to the fields
	`gbuffer_encode`/`gbuffer_decode` (shaders/gbuffer.hlsli) actually touch
	-- `position`/`view`/`alpha` are not part of the G-buffer at all (that
	file's own top comment), so they have no home here either, the same
	"only the fields this file reads" shape `brdf_test.odin`'s own
	`Test_Light_Sample`/`Test_Radiance` already keep to.
*/
@(private)
Gbuffer_Surface :: struct {
	normal:     [3]f32,
	base_color: [3]f32,
	occlusion:  f32,
	emissive:   [3]f32,

	shading_model: Shading_Model,

	metallic:       f32,
	roughness:      f32,
	specular:       [3]f32,
	glossiness:     f32,
	specular_power: f32,
	bands:          f32,
	rim:            f32,
	subsurface:     [3]f32,
	thickness:      f32,
}

// The four targets' own four floats apiece -- mirrors `Gbuffer_Encoded`
// (shaders/gbuffer.hlsli).
@(private)
Gbuffer_Encoded :: struct {
	a, b, c, d: [4]f32,
}

// Mirrors `gbuffer_encode` (shaders/gbuffer.hlsli) statement for statement.
// `shading_model_index` (shading.odin) is the same single source of truth
// the real dispatchers already use for the enum-to-float mapping, reused
// here rather than re-derived.
@(private)
gbuffer_encode :: proc(s: Gbuffer_Surface) -> Gbuffer_Encoded {
	param_x, param_y, param_z, param_w: f32

	switch s.shading_model {
	case .BLINN_PHONG:
		param_x = s.specular_power
	case .PBR_METALLIC:
		param_x = s.metallic
		param_y = s.roughness
	case .PBR_SPECGLOSS:
		param_x = s.specular.x
		param_y = s.specular.y
		param_z = s.specular.z
		param_w = s.glossiness
	case .TOON:
		param_x = s.bands
		param_y = s.rim
	case .SUBSURFACE:
		param_x = s.subsurface.x
		param_y = s.subsurface.y
		param_z = s.subsurface.z
		param_w = s.thickness
	case .UNLIT:
	// nothing extra to carry
	}

	oct := gbuffer_encode_normal(s.normal)

	g: Gbuffer_Encoded
	g.a = {s.base_color.x, s.base_color.y, s.base_color.z, s.occlusion}
	g.b = {oct.x, oct.y, shading_model_index(s.shading_model), param_x}
	g.c = {s.emissive.x, s.emissive.y, s.emissive.z, param_y}
	g.d = {param_z, param_w, 0, 0}
	return g
}

// Mirrors `gbuffer_decode` (shaders/gbuffer.hlsli) statement for statement,
// minus the `position`/`view` arguments -- those are reconstructed from
// depth and the camera in the real shader, not decoded from the G-buffer
// itself, so a caller here supplies them separately if it wants a full
// `Surface` rather than reading them off this struct.
@(private)
gbuffer_decode :: proc(g: Gbuffer_Encoded) -> Gbuffer_Surface {
	s: Gbuffer_Surface

	s.normal     = gbuffer_decode_normal({g.b.x, g.b.y})
	s.base_color = {g.a.x, g.a.y, g.a.z}
	s.occlusion  = g.a.w
	s.emissive   = {g.c.x, g.c.y, g.c.z}

	s.shading_model = Shading_Model(int(math.round(g.b.z)))

	param_x := g.b.w
	param_y := g.c.w
	param_z := g.d.x
	param_w := g.d.y

	switch s.shading_model {
	case .BLINN_PHONG:
		s.specular_power = param_x
	case .PBR_METALLIC:
		s.metallic  = param_x
		s.roughness = param_y
	case .PBR_SPECGLOSS:
		s.specular   = {param_x, param_y, param_z}
		s.glossiness = param_w
	case .TOON:
		s.bands = param_x
		s.rim   = param_y
	case .SUBSURFACE:
		s.subsurface = {param_x, param_y, param_z}
		s.thickness  = param_w
	case .UNLIT:
	}

	return s
}

// Round-trips one f32 through actual IEEE 754 half-float storage --
// `R16G16B16A16_FLOAT`'s own precision floor, which `gbuffer_test.odin`
// applies to every channel of a `Gbuffer_Encoded` between encode and decode
// so its own round-trip sweep measures what the real texture format would
// actually do to these numbers, not an infinite-precision idealization of
// the packing math alone.
@(private)
quantize_f16 :: proc(x: f32) -> f32 {
	return f32(f16(x))
}
