package matchbox

/*
	Environment probe -- image-based lighting
	-------------------------------------------
	The third of `Ambient_Kind`'s three modules (lighting.odin): a baked
	environment feeding the diffuse term of every shading model and the
	specular term of the two PBR ones, `lighting_plan.md` section 4's own
	"reflection probes" line and `lighting_rework.md` section 5's P4 "an
	environment probe with prefiltered IBL feeding the PBR models".

	**What gets generated at load, on the GPU, and what is approximated --
	stated plainly rather than left to be discovered:**

	- **The diffuse irradiance map is a real convolution**, not a stand-in --
	  `probe_irradiance.frag.hlsl` sums the source environment over the whole
	  hemisphere around each baked direction, cosine-weighted, the same
	  discrete Riemann-sum shape `pbr_test.odin`'s own furnace integral uses.
	  Reduced sample counts (12x24 per baked texel, at a low resolution) are
	  the only real cost, since this runs once at load rather than per frame.
	- **The prefiltered specular map is also a real convolution, of a
	  simplification.** A physically correct prefilter importance-samples the
	  GGX distribution itself; this bakes a plain cosine-weighted cone blur
	  instead, whose half-angle widens with `roughness^2` the same way GGX's
	  own lobe does (see `probe_prefilter.frag.hlsl`'s own top comment). The
	  cost: a rough metal's reflection here is a soft, roughly-Lambertian-
	  falloff blur rather than GGX's own longer-tailed highlight shape --
	  close in overall brightness (both are normalized, energy-preserving
	  kernels -- see `ibl_test.odin`'s uniform-environment check) but visibly
	  rounder at the edges of a highlight than a true GGX prefilter.
	- **The BRDF integration term is not generated at all -- it is an
	  analytic approximation**, `pbr_env_brdf_approx` (`brdf/pbr_common.hlsli`),
	  a closed-form polynomial fit (Karis 2014 / Lazarov 2013) standing in for
	  what a real split-sum implementation bakes into a LUT texture. This
	  is the one of the three pieces the plan calls out
	  (`lighting_rework.md`'s P4 brief) that this phase does not render at
	  all: no bake pass, no texture, no extra sampler slot -- see that
	  function's own doc comment for the closed-form anchor it does and does
	  not hit exactly.

	**Neither baked map is a real `TextureCube`.** Both are one
	`Texture2DArray` apiece (6 layers for irradiance, `6 * level_count` for
	prefiltered), addressed by a hand-rolled direction-to-(face, uv)
	projection (`probe_layer_uv`, `lighting_core.hlsli`) rather than hardware
	cube-map sampling. This is a deliberate, safety-first choice and not an
	oversight: hardware `TextureCube` addressing is left-handed on every API
	this package targets, and this package already carries one hard-won fix
	for that (`skybox_cubemap.frag.hlsl`'s own x-negation, discovered by
	actually seeing a mirrored sky render). There is no GPU in this
	environment to render anything and see whether a *second*,
	independently-derived cube convention agrees with the hardware's own --
	so rather than add a second unverifiable handedness assumption, the two
	new maps reuse the exact projection `shadow_cube.odin`/`shadow/cube.hlsli`
	already established and tested (`shadow_test.odin`) for the point-light
	cube shadow map: pick a face by `shadow_cube_face_index`, then project
	the query direction through that face's own camera basis to get a UV.
	Baking uses the identical basis to build each face's own render, by
	reusing the skybox's own vertex shader (`skybox.vert.hlsl`) the same way
	`draw_skybox` does -- see `create_environment_probe` below. The cost is
	real (no hardware bilinear blend across a face seam, the same trade
	`shadow_cube.odin` already documented and accepted), the risk avoided is
	larger: a wrong-handed bake would put ambient light on the wrong side of
	every object in every scene that uses it, silently, with nothing to
	catch it.

	**Only a `.CUBEMAP` `Skybox` is a valid source.** A `.PANORAMA` would
	need its own conversion to a directionally-addressable source first,
	which is a second loader's worth of work this phase does not need to
	take on -- `create_environment_probe` returns
	`Environment_Probe_Error.Source_Not_Cubemap` rather than silently reading
	garbage from a texture of the wrong shape.
*/

import "core:log"
import "core:math/linalg"

import sdl "vendor:sdl3"

/*
	How big to bake each of the environment probe's two maps -- see
	`create_environment_probe`'s own doc comment for what each number costs.
	Every field defaulted, per CLAUDE.md's "configuration rides in as a
	defaulted struct" -- there is no one right resolution or level count for
	every scene, so this is a parameter rather than a loose constant.
*/
Environment_Probe_Settings :: struct {
	irradiance_resolution: int, // per face, in texels -- diffuse varies slowly, so this can be small
	prefilter_resolution:  int, // per face, in texels -- shared by every roughness level (see this struct's own field below for why they cannot each pick their own)
	prefilter_level_count: int, // how many roughness buckets brdf/pbr_common.hlsli's pbr_environment_specular blends between
}

/*
	16x16 diffuse faces, 32x32 specular faces, 5 roughness levels -- small
	enough that baking is a handful of milliseconds' worth of full-screen
	draws, and the diffuse term in particular does not benefit from more:
	irradiance is, by construction, a low-frequency function of direction (a
	cosine-weighted hemisphere integral is a strong low-pass filter on its
	own), so a high-resolution irradiance map spends texels on detail the
	convolution has already erased.

	`prefilter_resolution` is one number rather than one per level -- unlike
	a real mip chain, every one of `prefilter_level_count`'s layers is a
	*layer* of one `Texture2DArray` (see this file's own top comment), and
	every layer of one texture must share its width and height. A real
	implementation halving resolution per roughness level the way an actual
	mip chain would is exactly the thing this design trades away for not
	needing a second, unverifiable hardware-cubemap-addressing bet -- see
	that same top comment.
*/
ENVIRONMENT_PROBE_DEFAULTS :: Environment_Probe_Settings{
	irradiance_resolution = 16,
	prefilter_resolution  = 32,
	prefilter_level_count = 5,
}

/*
	The baked result -- two `Texture2DArray`s and how many roughness levels
	the second one has. Lives on `Renderer.lighting.probe`
	(`set_environment_probe`) once bound; the zero value is "no probe",
	which is what lets `Ambient_Kind.ENVIRONMENT_PROBE` be selected before
	one is ever loaded and degrade to no ambient light rather than crash --
	see `Renderer.default_probe_texture`'s own doc comment (render.odin).
*/
Environment_Probe :: struct {
	irradiance:              ^sdl.GPUTexture, // Texture2DArray, 6 layers, one per face
	prefiltered:             ^sdl.GPUTexture, // Texture2DArray, 6 * prefiltered_level_count layers, layer = level * 6 + face
	prefiltered_level_count: i32,
}

/*
	Bakes `source`'s own cube map into a new `Environment_Probe` -- does **not**
	install it as the scene's own ambient; call `set_environment_probe` with
	the result to do that. Split the way `load_skybox_cubemap` (a pure
	loader) and drawing it (a separate call) already are: baking a probe is
	comparatively expensive and a game may want to hold on to more than one
	(day and night, say) and switch between them without re-baking.

	`source` must be a `.CUBEMAP` skybox -- see this file's own top comment
	for why a `.PANORAMA` is refused rather than converted.
*/
create_environment_probe :: proc(
	source:   Skybox,
	settings: Environment_Probe_Settings = ENVIRONMENT_PROBE_DEFAULTS,
) -> (probe: Environment_Probe, err: Error) {
	if source.kind != .CUBEMAP || source.texture == nil {
		return {}, Environment_Probe_Error.Source_Not_Cubemap
	}

	r := &mbi.renderer
	if r.device == nil do return {}, Gpu_Error.Texture_Creation_Failed

	irradiance_size := max(settings.irradiance_resolution, 1)
	prefilter_size  := max(settings.prefilter_resolution, 1)
	level_count     := max(settings.prefilter_level_count, 1)

	format := r.lighting.targets.format

	irradiance := create_cube_array_render_target(irradiance_size, 6, format) or_return
	defer if err != nil do sdl.ReleaseGPUTexture(r.device, irradiance)

	prefiltered := create_cube_array_render_target(prefilter_size, 6 * level_count, format) or_return
	defer if err != nil do sdl.ReleaseGPUTexture(r.device, prefiltered)

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil do return {}, Gpu_Error.Submit_Failed

	source_binding := sdl.GPUTextureSamplerBinding{texture = source.texture, sampler = source.sampler}

	for face in 0 ..< 6 {
		vert_data := probe_face_vert_data(face)

		target := sdl.GPUColorTargetInfo{
			texture              = irradiance,
			layer_or_depth_plane = u32(face),
			load_op              = .DONT_CARE,
			store_op             = .STORE,
		}

		pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
		if pass == nil {
			_ = sdl.CancelGPUCommandBuffer(cmd)
			return {}, Gpu_Error.Submit_Failed
		}

		sdl.BindGPUGraphicsPipeline(pass, r.pipelines.probe_irradiance)
		sdl.BindGPUFragmentSamplers(pass, 0, &source_binding, 1)
		sdl.PushGPUVertexUniformData(cmd, 0, &vert_data, size_of(vert_data))
		sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
		sdl.EndGPURenderPass(pass)
	}

	for level in 0 ..< level_count {
		// 0 at level 0 (a mirror -- see probe_prefilter.frag.hlsl's own
		// handling of that case) up to 1 at the last level, matching how
		// pbr_environment_specular turns `roughness` back into a level with
		// `roughness * (level_count - 1)`.
		roughness := f32(level) / f32(max(level_count - 1, 1))
		frag_data := Probe_Prefilter_Frag_Data{roughness = roughness}

		for face in 0 ..< 6 {
			vert_data := probe_face_vert_data(face)

			target := sdl.GPUColorTargetInfo{
				texture              = prefiltered,
				layer_or_depth_plane = u32(level * 6 + face),
				load_op              = .DONT_CARE,
				store_op             = .STORE,
			}

			pass := sdl.BeginGPURenderPass(cmd, &target, 1, nil)
			if pass == nil {
				_ = sdl.CancelGPUCommandBuffer(cmd)
				return {}, Gpu_Error.Submit_Failed
			}

			sdl.BindGPUGraphicsPipeline(pass, r.pipelines.probe_prefilter)
			sdl.BindGPUFragmentSamplers(pass, 0, &source_binding, 1)
			sdl.PushGPUVertexUniformData(cmd, 0, &vert_data, size_of(vert_data))
			sdl.PushGPUFragmentUniformData(cmd, 0, &frag_data, size_of(frag_data))
			sdl.DrawGPUPrimitives(pass, 3, 1, 0, 0)
			sdl.EndGPURenderPass(pass)
		}
	}

	if !sdl.SubmitGPUCommandBuffer(cmd) {
		return {}, Gpu_Error.Submit_Failed
	}

	probe = Environment_Probe{
		irradiance              = irradiance,
		prefiltered             = prefiltered,
		prefiltered_level_count = i32(level_count),
	}

	return probe, nil
}

/*
	One `Texture2DArray`, `layer_count` layers of `size`x`size`, usable both
	as a render target (baking) and sampled afterward -- what
	`create_environment_probe` needs and `create_gpu_texture` (upload.odin)
	does not provide, since every existing caller of that one only ever
	samples what it makes, never renders into it.
*/
@(private = "file")
create_cube_array_render_target :: proc(size, layer_count: int, format: sdl.GPUTextureFormat) -> (^sdl.GPUTexture, Error) {
	texture := sdl.CreateGPUTexture(mbi.renderer.device, {
		type                 = .D2_ARRAY,
		format               = format,
		usage                = {.COLOR_TARGET, .SAMPLER},
		width                = u32(size),
		height               = u32(size),
		layer_count_or_depth = u32(layer_count),
		num_levels           = 1,
	})

	if texture == nil do return nil, Gpu_Error.Texture_Creation_Failed
	return texture, nil
}

/*
	The camera basis `skybox.vert.hlsl` needs to render face `face`'s own
	90-degree view -- `shadow_cube_face_direction`'s own (direction, up)
	pair, squared into an orthonormal (right, up, forward) triple the exact
	same way `look_at_matrix` squares its own `up` argument against `f`
	(`s = normalize(cross(f, up))`, `u = cross(s, f)`). This has to be the
	same construction `probe_face_basis` (`lighting_core.hlsli`) uses at read
	time, or a bake would write a face's own image rotated relative to
	however that function later addresses it -- see this file's own top
	comment for why matching an existing, tested convention was chosen over
	deriving a new one that only this function and its shader-side twin
	would ever check against each other.

	`right`/`up` need no extra scaling: a 90-degree field of view has
	`tan(45 deg) == 1`, so the unit-length basis vectors already are what
	`draw_skybox` would otherwise multiply by `tan(fov/2) * aspect`.
*/
@(private = "file")
probe_face_vert_data :: proc(face: int) -> Skybox_Vert_Data {
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

/*
	Installs `probe` as the scene's own environment probe, releasing
	whatever was bound before -- `set_lighting`'s own "replace the whole
	struct" shape, applied to the one piece of ambient/environment state
	that is a GPU resource rather than a plain value and therefore cannot
	live on `Lighting_Settings` itself (see that struct's own doc comment).
	Selecting `Ambient_Kind.ENVIRONMENT_PROBE` (`set_lighting`) is what
	actually turns this on; calling this alone changes nothing a shader
	reads.
*/
set_environment_probe :: proc(probe: Environment_Probe) {
	old := mbi.renderer.lighting.probe
	mbi.renderer.lighting.probe = probe
	destroy_environment_probe(&old)
}

// Releases a probe's own two textures. Joins the `destroy :: proc{...}`
// group (destroy.odin) per CLAUDE.md.
destroy_environment_probe :: proc(probe: ^Environment_Probe) {
	device := mbi.renderer.device
	if device != nil {
		if probe.irradiance  != nil do sdl.ReleaseGPUTexture(device, probe.irradiance)
		if probe.prefiltered != nil do sdl.ReleaseGPUTexture(device, probe.prefiltered)
	}
	probe^ = Environment_Probe{}
}
