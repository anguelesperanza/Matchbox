package matchbox

import sdl "vendor:sdl3"

/*
	How many sampled textures/samplers mesh.frag.hlsl declares -- 1 base
	colour, 3 material maps, 2 PCF/PCSS shadow maps, 1 CASCADED array, 1 CUBE
	array, 1 environment probe irradiance map, 1 environment probe
	prefiltered map, at t0-t9/s0-s9 (see that file's own top comment). Passed
	to `create_builtin_shader` for `Shaders.mesh_frag` below rather than a
	bare literal at the call site, so `render_test.odin` can pin
	the actual value `init` hands `CreateGPUShader` under Vulkan's guaranteed
	per-stage floor (16, for both `maxPerStageDescriptorSampledImages` and
	`maxPerStageDescriptorSamplers`) rather than merely asserting on source
	text.

	**Grew from 8 to 10 in P4**, for the environment probe's own two maps
	(`ambient.odin`) -- still five under the floor `render_test.odin` pins,
	and comfortably clear of it: a real BRDF integration LUT would have been
	a third texture and pushed this to 11, still fine, but P4 approximates
	that term analytically instead (`pbr_env_brdf_approx`,
	brdf/pbr_common.hlsli) rather than spending a slot and a bake pass on it
	-- see that function's own doc comment for the trade.

	Not a CLAUDE.md "configuration" constant -- nothing about this number is a
	judgement call a game could reasonably want to override, since it has to
	equal however many `Texture2D`/`Texture2DArray` slots the compiled shader
	binary actually declares or `CreateGPUShader` and every bind call built
	against it disagree with reality. The same "a fixed compile-time number
	that only a comment keeps in step with the shader source" shape
	`MAX_CASCADES`/`MAX_CASCADES_HLSL` (shadow.odin,
	shaders/shadow/cascaded.hlsli) already has.
*/
MESH_FRAG_SAMPLER_COUNT :: 10

/*
	How many sampled textures/samplers `deferred_lighting.frag.hlsl`
	declares -- the shader at risk P6 was warned about, since it needs
	everything `mesh.frag.hlsl` needs for shading (shadow maps, the
	environment probe's own two) *plus* the four G-buffer targets and its
	own sampled depth target, even though it drops the four material
	textures `mesh.frag.hlsl` reads (base colour, metallic-roughness,
	occlusion, emissive arrive through the G-buffer instead): four G-buffer
	targets, one depth target, two PCF/PCSS shadow maps, one CASCADED array,
	one CUBE array, two environment-probe maps -- t0-t10.

	Five under Vulkan's guaranteed per-stage floor of 16
	(`gbuffer_test.odin` pins the actual value the same way
	`render_test.odin` pins `MESH_FRAG_SAMPLER_COUNT`), so this did not need
	the "stop and report" the phase brief asked for if it had come out
	otherwise.
*/
DEFERRED_LIGHTING_SAMPLER_COUNT :: 11

// The built-in shader set, compiled from matchbox/shaders and loaded by init.
//
// One vertex shader serves every draw: the old test.vert and font.vert had
// identical bodies and differed only in the field order of their uniform block.
Shaders :: struct {
	quad:    ^sdl.GPUShader,
	sprite:  ^sdl.GPUShader,
	rect:    ^sdl.GPUShader,
	outline: ^sdl.GPUShader,
	font:    ^sdl.GPUShader,
	shape:   ^sdl.GPUShader,

	// 3D. The first vertex shader that is not `quad`, because it is the first
	// thing that reads geometry instead of building it from a uniform block.
	mesh:      ^sdl.GPUShader,
	mesh_line: ^sdl.GPUShader,

	/*
		The one fragment shader every solid mesh pipeline shares now, textured
		or not -- see mesh.frag.hlsl's own doc comment. Before this rework
		there were two of these (`mesh_flat`/`mesh_textured`), differing only
		in whether they sampled a base-colour texture, which forced
		`lighting.hlsli`'s two shadow maps to sit at different register slots
		in each and `draw_model_immediate` to compute which. Binding a 1x1
		white default texture for an untextured part removes the need for a
		second shader entirely.
	*/
	mesh_frag: ^sdl.GPUShader,

	// mesh.vert with a skeleton in front of it. Shares every fragment shader
	// the unskinned one uses -- only the vertex stage differs.
	mesh_skinned: ^sdl.GPUShader,

	/*
		DEFERRED's own two shaders -- see pipeline_deferred.odin's own top
		comment and gbuffer.frag.hlsl/deferred_lighting.frag.hlsl. `gbuffer_frag`
		pairs with mesh.vert/mesh_skinned.vert exactly the way mesh_frag
		does, since a G-buffer fill pass reads the identical vertex layout
		and the identical Material cbuffer a forward draw does -- only the
		fragment stage's own job (fill four targets rather than shade one
		colour) differs. `fullscreen` is deferred_lighting.frag.hlsl's own
		vertex shader (fullscreen.vert.hlsl) -- see that file's own doc
		comment for why it is not skybox's.
	*/
	gbuffer_frag:           ^sdl.GPUShader,
	fullscreen:             ^sdl.GPUShader,
	deferred_lighting_frag: ^sdl.GPUShader,

	// The shadow pass's fragment shader -- writes nothing, paired with
	// mesh/mesh_skinned's own vertex shaders rather than one of its own. See
	// shadow.frag.hlsl.
	shadow: ^sdl.GPUShader,

	// The sky. One vertex shader making a triangle out of nothing, and a
	// fragment shader per source format.
	skybox:          ^sdl.GPUShader,
	skybox_panorama: ^sdl.GPUShader,
	skybox_cubemap:  ^sdl.GPUShader,

	// Post-processing. All three take the shared quad vertex shader.
	post: ^sdl.GPUShader,
	psx:  ^sdl.GPUShader,
	vhs:  ^sdl.GPUShader,

	/*
		The bloom chain's own three -- also on the shared quad vertex shader,
		since every one of them is a full-screen rectangle over some level of
		the chain. Three rather than one because the three passes genuinely
		differ: the prefilter reads a brightness knee the other two do not
		have, and the upsample runs a different kernel and a different blend.
		See bloom.odin's own top comment for the pass order and
		shaders/bloom.hlsli for the two kernels they share.
	*/
	bloom_prefilter:  ^sdl.GPUShader,
	bloom_downsample: ^sdl.GPUShader,
	bloom_upsample:   ^sdl.GPUShader,

	// Environment probe baking -- both take the skybox's own vertex shader
	// (Shaders.skybox), reused rather than duplicated: a per-face camera
	// basis is a per-face camera basis whether the fragment shader that
	// reads it draws a sky or convolves one. See ambient.odin's own top
	// comment.
	probe_irradiance: ^sdl.GPUShader,
	probe_prefilter:  ^sdl.GPUShader,

	/*
		The tonemap resolve -- exposure, one of `Tonemap`'s curves, then the
		gamma encode every colour in this package has always used. Takes the
		shared quad vertex shader, the same as the other post shaders above,
		but is not one of them: `Post_Effect` is a game's own choice drawn
		over a `Render_Target` it owns, and this runs unconditionally, once
		per 3D pass, over the internal HDR target `Renderer.lighting.targets`
		owns instead. See tonemap.odin.
	*/
	tonemap: ^sdl.GPUShader,
}

/*
	One pipeline per fragment shader.

	SDL3 has no dynamic shader or blend state -- the combination is baked into
	an object at creation. That is the whole reason this port exists: the
	previous backend got its dynamic state from VK_EXT_shader_object, which
	Intel's Vulkan driver does not provide at any driver version currently
	shipping, so an Arc B580 could not start the game at all.

	All of them share the one vertex shader and the same alpha blend.
*/
Pipelines :: struct {
	sprite:  ^sdl.GPUGraphicsPipeline,
	rect:    ^sdl.GPUGraphicsPipeline,
	outline: ^sdl.GPUGraphicsPipeline,
	font:    ^sdl.GPUGraphicsPipeline,
	shape:   ^sdl.GPUGraphicsPipeline, // ellipses and triangles, cut out in the fragment stage

	// The odd one out, and the reason create_pipeline takes arguments now: it
	// has its own vertex shader, a third vertex attribute, depth testing on,
	// back faces culled, and a depth-stencil target the others do not have.
	// Textured and untextured parts alike -- see `mesh_frag`'s own comment.
	mesh:    ^sdl.GPUGraphicsPipeline,

	// The same vertex shader and vertex layout as `mesh`, drawing line lists
	// instead of triangles and shading them flat. Wireframes, bounding boxes
	// and the ground grid.
	line:    ^sdl.GPUGraphicsPipeline,

	// `mesh` again, for parts a skeleton deforms. One rather than the two
	// this used to be (`mesh_skinned`/`mesh_skinned_textured`): both read
	// `mesh_frag` now, so the only thing that ever distinguished them --
	// whether a part carried a texture -- no longer picks a pipeline at all.
	mesh_skinned: ^sdl.GPUGraphicsPipeline,

	/*
		DEFERRED's own three -- see pipeline_deferred.odin's own top comment.
		`gbuffer`/`gbuffer_skinned` are `mesh`/`mesh_skinned`'s own siblings,
		built against the four G-buffer targets (`color_formats`,
		`create_pipeline`) and the G-buffer's own depth texture rather than
		the HDR target and the shared main depth texture, with blending off
		(`blend = .NONE`) -- see `Material.transparent`'s own doc
		comment (material.odin) for why a G-buffer fill pass cannot blend at
		all. `deferred_lighting` is the fullscreen resolve, built the same
		shape `skybox_panorama`/`skybox_cubemap` already are
		(`Vertex_Layout.NONE`, `depth_ignore = true`, the HDR target's own
		colour format) so it can run in the identical final pass those two
		and the forward-fallback mesh pipelines already share.
	*/
	gbuffer:           ^sdl.GPUGraphicsPipeline,
	gbuffer_skinned:   ^sdl.GPUGraphicsPipeline,
	deferred_lighting: ^sdl.GPUGraphicsPipeline,

	// Depth-only, biased, no colour target at all -- the shadow pass. Two for
	// the same reason mesh/mesh_skinned are two: a skinned caster needs the
	// skeleton's own vertex shader.
	shadow:         ^sdl.GPUGraphicsPipeline,
	shadow_skinned: ^sdl.GPUGraphicsPipeline,

	// Depth attached but neither tested nor written, so the sky is a background
	// rather than very distant geometry.
	skybox_panorama: ^sdl.GPUGraphicsPipeline,
	skybox_cubemap:  ^sdl.GPUGraphicsPipeline,

	// A render target drawn back over the window, with or without an effect on
	// the way. Colour-only and depthless, like every other 2D pipeline.
	post: ^sdl.GPUGraphicsPipeline,
	psx:  ^sdl.GPUGraphicsPipeline,
	vhs:  ^sdl.GPUGraphicsPipeline,

	// The tonemap resolve -- see Shaders.tonemap's own comment. Built against
	// the swapchain's own format like every other 2D pipeline here: it writes
	// into current_color_texture(), never into the HDR target itself.
	tonemap: ^sdl.GPUGraphicsPipeline,

	/*
		The bloom chain -- all three built against the HDR target's own float
		format, not the swapchain's, because every level of the chain holds
		unbounded linear light the same way the scene target does (bloom.odin).
		Depthless like every other 2D pipeline here.

		`bloom_upsample` is the one pipeline in this package with an additive
		blend rather than the alpha blend everything else shares
		(`Color_Blend.ADDITIVE`, create_pipeline) -- see
		bloom_upsample.frag.hlsl for why adding into the destination *is* the
		mechanism rather than an optimization of it.
	*/
	bloom_prefilter:  ^sdl.GPUGraphicsPipeline,
	bloom_downsample: ^sdl.GPUGraphicsPipeline,
	bloom_upsample:   ^sdl.GPUGraphicsPipeline,

	// Environment probe baking -- see Shaders.probe_irradiance/probe_prefilter's
	// own comment. Built against the HDR target's own float format
	// (ambient.odin's own top comment), not the swapchain's: these write
	// into a probe's own textures, never onto anything a game will see
	// directly.
	probe_irradiance: ^sdl.GPUGraphicsPipeline,
	probe_prefilter:  ^sdl.GPUGraphicsPipeline,
}

/*
	Everything lighting owns: the scene's own settings, the light list on both
	sides of the upload, and the shadow system's state -- grouped under one
	field on `Renderer` (`lighting` below) per CLAUDE.md's "group like data
	into structs" rather than left as loose fields the way `Lighting_Data` and
	`Shadow` used to be side by side. See `lighting_rework.md` section 4.
*/
Lighting :: struct {
	settings: Lighting_Settings, // lighting.odin -- set by set_lighting

	// The light list, CPU side and GPU side. `light_data` is packed and
	// ready to upload -- see `light_uniform` (light.odin) -- and
	// `light_buffer`/`light_transfer` are its device-side twin, grown on
	// demand and rewritten through the transfer buffer rather than
	// recreated every call, the same shape `Animation_Pose.joint_buffer`
	// already has for the joint palette. `light_capacity` is how many
	// elements `light_buffer` currently holds, which is not `len(light_data)`
	// once the list has shrunk from a previous, longer one.
	light_data:     [dynamic]Light_Uniform,
	light_buffer:   ^sdl.GPUBuffer,
	light_transfer: ^sdl.GPUTransferBuffer,
	light_capacity: int,

	shadow: Shadow_State, // shadow.odin / shadow_standard.odin

	// CLUSTERED's own per-frame assignment -- see light_cull.odin's own top
	// comment. Rebuilt every frame that pipeline is selected, unlike
	// light_data/light_buffer above which only rebuild when a game calls
	// set_lights, since a cluster's own shape depends on the camera and the
	// camera may move every frame even when the lights do not.
	cluster: Cluster_State,

	// The baked diffuse/specular environment maps `Ambient_Kind.ENVIRONMENT_PROBE`
	// reads (lighting.odin, ambient.odin) -- zero value is "no probe loaded",
	// which is what makes selecting that ambient kind before ever calling
	// create_environment_probe degrade to no ambient light rather than a crash.
	probe: Environment_Probe,

	// The HDR scene target the 3D pass actually draws into, and the tonemap
	// resolve that turns it back into whatever begin_drawing_3d was called
	// for. See tonemap.odin's own top comment for why this cannot simply be
	// `Render_Target`'s own format.
	targets: Lighting_Targets,

	// DEFERRED's own four fill targets and their own depth texture -- see
	// Gbuffer_Targets' own doc comment (gbuffer.odin) for why this is a
	// texture set of its own rather than reusing targets/depth_texture.
	// Zero value ("no textures yet") until a game actually selects
	// DEFERRED, the same "allocated on first use" shape targets/
	// depth_texture already have for 3D itself.
	gbuffer: Gbuffer_Targets,

	// The bloom chain's own half-resolution levels -- see Bloom_Targets
	// (bloom.odin). Zero value until a game actually turns bloom on, and
	// released again the first frame after it turns it off, which is the one
	// place this differs from the two texture sets above: a game toggling
	// bloom is an ordinary thing to do, where a game toggling DEFERRED is
	// not.
	bloom: Bloom_Targets,
}

// GPU-side state. Internal plumbing -- games should not need to touch any of
// this, which is why Matchbox_Info keeps it behind `mbi.renderer` instead of
// promoting the fields.
Renderer :: struct {
	device:    ^sdl.GPUDevice,
	shaders:   Shaders,
	pipelines: Pipelines,

	cmd:          ^sdl.GPUCommandBuffer,
	pass:         ^sdl.GPURenderPass,
	swapchain:    ^sdl.GPUTexture,
	frame_active: bool, // false when the swapchain had nothing for us this frame

	// The unit quad, uploaded once. Every mesh used to carry its own identical
	// copy of these four vertices and six indices.
	quad_verts:   ^sdl.GPUBuffer,
	quad_indices: ^sdl.GPUBuffer,

	// Two samplers for the whole program: nearest for sprites, linear for the
	// font atlas. The old backend allocated these out of a descriptor pool with
	// room for 32, which put a ceiling of about two dozen sprites on a program.
	sprite_sampler: ^sdl.GPUSampler,

	/*
		1x1 white, sampled wherever a mesh part has no base colour texture of
		its own. This is what lets `mesh.frag.hlsl` be one shader for textured
		and untextured parts alike -- see that file's own doc comment and
		`lighting_rework.md` section 3.4. The same trick `init` already used
		for the shadow maps' own placeholders, applied to the other side of
		the same sampler slot.
	*/
	default_texture: ^sdl.GPUTexture,

	/*
		1x1 black, sampled at both of the environment probe's own slots
		(`irradiance_map`/`prefiltered_map`, mesh.frag.hlsl) whenever
		`Renderer.lighting.probe` is empty -- the same "always something valid
		bound" trick `default_texture` already plays for the material maps,
		applied to `Ambient_Kind.ENVIRONMENT_PROBE` so selecting it with no
		probe ever loaded reads as zero ambient light rather than sampling a
		nil texture. Black rather than white here: `default_texture` stands
		in for a *factor* (1.0 is "no change"), this stands in for *emitted
		light* (0.0 is "none"), and the two would be the wrong value swapped.
	*/
	default_probe_texture: ^sdl.GPUTexture,

	/*
		A 1-element `Cluster_Range{0, 0}` and a 1-element `uint(0)` -- bound
		whenever `Lighting_Settings.pipeline` is not `CLUSTERED`, or is
		`CLUSTERED` but `Lighting.cluster`'s own buffers have not been built
		yet (the first frame the pipeline is selected, before
		`pipeline_clustered_begin` runs). The same "always something valid
		bound" trick `default_texture`/`default_probe_texture` already play,
		applied to the two storage buffers `lighting_core.hlsli` declares
		unconditionally (`cluster_ranges`/`cluster_light_indices`) so
		`FORWARD` never has to leave either slot empty. See
		`pipeline_forward_cluster_buffers` (pipeline_forward.odin), the one
		reader.
	*/
	default_cluster_ranges_buffer:        ^sdl.GPUBuffer,
	default_cluster_light_indices_buffer: ^sdl.GPUBuffer,

	/*
		Linear, clamped on all three axes -- the sampler for reading an
		internal texture whose edges are edges rather than a wrap-around.

		Two things want that. The environment probe reads both its own maps
		through it (see ambient.odin's own doc comment on why the prefiltered
		map is read with an explicit level rather than automatic derivatives),
		shared by both probe slots and by the 1x1 placeholder above the same
		way `sprite_sampler` is shared by every untextured material slot. And
		every pass of the bloom chain reads through it too (bloom.odin), where
		the filtering *is* the effect and the clamping is what keeps a bright
		spot on the left edge of the screen from bleeding into the right one.

		Named for what it is rather than for the first thing that wanted it:
		it was `probe_sampler` until bloom turned out to want the identical
		state, and two identical samplers with different names would have been
		the worse answer.
	*/
	linear_clamp_sampler: ^sdl.GPUSampler,

	// Linear, and wrapping across the seam where a panorama's longitude comes
	// back round to itself. Clamped in v, so the poles do not bleed into each
	// other. The cube map wants clamping on both, because the hardware filters
	// across its own face seams and wrapping would fight it.
	skybox_wrap_sampler:  ^sdl.GPUSampler,
	skybox_clamp_sampler: ^sdl.GPUSampler,
	font_sampler:   ^sdl.GPUSampler,

	// Nested clip rectangles, in window pixels and already intersected. See
	// clip.odin.
	clip_stack: [MAX_CLIP_DEPTH]sdl.Rect,
	clip_depth: int,

	// What the current render pass already has bound. Binding is pass state, so
	// all of this is void the moment a pass ends and bind_cache_reset says so.
	//
	// Every draw used to re-bind the pipeline, the vertex buffer and the index
	// buffer, however many of them ran back to back with identical state. A
	// screen of two thousand rects is one pipeline and one quad, described two
	// thousand times.
	bound_pipeline:     ^sdl.GPUGraphicsPipeline,
	bound_texture:      ^sdl.GPUTexture,
	bound_sampler:      ^sdl.GPUSampler,
	bound_quad:         bool, // the shared vertex and index buffers, which never change
	bound_joint_buffer: ^sdl.GPUBuffer, // a skinned model's palette; see draw_model

	// The all-identity fallback for a skinned model drawn with no animator --
	// see draw_model. Grown, never shrunk, so the common case of drawing the
	// same handful of rigs pays for one allocation rather than one a draw.
	identity_joints:       ^sdl.GPUBuffer,
	identity_joints_count: int,

	// 3D. The depth texture is made the first time a game asks for a 3D pass
	// and remade when the window changes size, so a program that never draws
	// 3D never pays for one. See render3d.odin.
	depth_texture: ^sdl.GPUTexture,
	depth_format:  sdl.GPUTextureFormat, // .INVALID until the first one is made
	depth_width:   i32,
	depth_height:  i32,

	// Where drawing is going: nil is the window, anything else is a texture the
	// game is building. See render_target.odin.
	target: ^Render_Target,

	/*
		The colour `clear_background` was last given, remembered rather than
		written straight to whatever it is clearing. begin_drawing_3d reads
		this to clear the internal HDR scene target (tonemap.odin) -- a
		target that has never been drawn into this frame has nothing of its
		own to load the way the old "load, do not clear" contract relied on,
		see that procedure's own comment. Every example in this repo calls
		clear_background immediately before its own begin_drawing_3d with
		nothing 2D drawn in between (checked by hand across all of them for
		this phase), so the background a game asked for is still what shows
		through -- it is carried across the two calls explicitly instead.
	*/
	background_color: [4]f32,

	// Lighting settings, the light list and the shadow system -- see
	// `Lighting`'s own doc comment. The scene half of this (`lighting.settings`,
	// `lighting.light_data`) is set whenever a game calls `set_lighting` or
	// `set_lights`; the per-frame half (the camera-derived `Scene_Frag_Data`)
	// is worked out and pushed by `push_lighting`, called from
	// `begin_drawing_3d` rather than from either setter, so a game may call
	// them anywhere -- including before `begin_drawing`.
	lighting: Lighting,

	mode_3d:         bool, // true between begin_drawing_3d and end_drawing_3d
	view_projection: matrix[4, 4]f32,
	camera3d:        Camera3D,

	// Whether draw_model is currently filling a shadow map rather than
	// drawing the scene it will be sampled by. See shadow_standard.odin.
	in_shadow_pass: bool,

	// The metallic-roughness, occlusion and emissive textures
	// draw_model_immediate last bound for the current part, in that order --
	// a second per-part cache alongside bound_texture/bound_sampler above
	// (which stays base-colour-only) rather than a fourth slot folded into
	// it, because bind_quad_state's 2D draws share bound_texture/bound_sampler
	// too and a sprite has never had three more textures to go with it. One
	// sampler serves all three (see Material_Textures' own doc comment on
	// why), so unlike bound_texture/bound_sampler there is no paired sampler
	// array to also compare.
	bound_material_textures: [3]^sdl.GPUTexture,

	// What draw_model_immediate has bound for the non-shadow-pass fragment
	// shader beyond the per-part textures above: the shadow maps for every
	// technique group (PCF/PCSS's two, CASCADED's one layered array, CUBE's
	// one layered array -- all three always bound regardless of which
	// technique is actually running, see Shadow_State's own doc comment) and
	// the light storage buffer. None of these change per part or per
	// pipeline switch the way the per-part textures do, but they can change
	// mid-pass if a game calls set_lighting or set_lights (growing the light
	// buffer) between draw_model calls.
	//
	// bound_cascade_maps/bound_cube_maps are single pointers, not arrays,
	// since P3b: CASCADED's up-to-eight maps and CUBE's six are each one
	// Texture2DArray now (one sampler apiece) rather than one GPUTexture per
	// layer -- see shadow.odin's own doc comment on Shadow_State for why.
	bound_shadow_maps:  [MAX_SHADOW_CASTERS]^sdl.GPUTexture,
	bound_cascade_maps: ^sdl.GPUTexture,
	bound_cube_maps:    ^sdl.GPUTexture,

	// The environment probe's own two maps -- {irradiance, prefiltered},
	// whichever of a real probe or default_probe_texture's own placeholder is
	// currently bound for each. See draw_model_immediate's own comment on
	// why these two always bind together.
	bound_probe_maps:   [2]^sdl.GPUTexture,

	bound_light_buffer: ^sdl.GPUBuffer,

	// CLUSTERED's own two storage buffers, or FORWARD's placeholders for the
	// same slots -- see pipeline_cluster_buffers (render3d.odin), the one
	// dispatcher that decides which.
	bound_cluster_ranges:        ^sdl.GPUBuffer,
	bound_cluster_light_indices: ^sdl.GPUBuffer,

	// draw_model calls made with casts_shadow = true before begin_drawing_3d
	// has a pass of any kind open yet, held until it does. See draw_model's
	// own doc comment.
	pending_shadow_models: [dynamic]Pending_Shadow_Model,

	/*
		DEFERRED's own queues -- see pipeline_deferred.odin's own top
		comment for the pass shape these exist to bridge. A draw_model call
		made while the G-buffer pass is open cannot draw a transparent or
		LINES-topology part into it at all (see Material.transparent's own
		doc comment, material.odin, and draw_model_immediate's own comment
		on in_deferred_forward_pass below) -- every such call is queued here,
		re-played once the final HDR pass is open, the same "hold until the
		right pass exists" shape pending_shadow_models above already has for
		a model marked casts_shadow before any pass exists yet.

		draw_skybox has the identical problem for a different reason: its
		own pipelines are built against the HDR target's single colour
		format, incompatible with the G-buffer pass's own four -- one
		pending slot rather than a list, since a game draws its sky at most
		once a frame (draw_skybox's own doc comment: "call it first").
	*/
	pending_deferred_forward_models: [dynamic]Pending_Shadow_Model,
	pending_skybox:                  Skybox,
	has_pending_skybox:              bool,

	// True while draw_model_immediate is replaying pending_deferred_forward_models
	// into the final HDR pass -- see that proc's own doc comment for exactly
	// which parts this makes it draw (transparent and/or LINES) versus skip
	// (everything already filled into the G-buffer). Not the same axis as
	// in_shadow_pass: a model can be replayed into the shadow pass and the
	// deferred forward pass in the same frame, for the same reason it can be
	// drawn into the ordinary scene pass and a shadow pass today.
	in_deferred_forward_pass: bool,

	// The shapes draw_cube and friends draw, built the first time one is asked
	// for. Same reasoning as the depth texture: a game that draws no 3D should
	// not be carrying a sphere it never uses. See shapes3d.odin.
	unit_cube:       Model,
	unit_cube_wires: Model,
	unit_plane:      Model,
	unit_sphere:     Model,

	// draw_grid's one grid, rebuilt when the numbers it was asked for change.
	grid:         Model,
	grid_slices:  int,
	grid_spacing: f32,
}

// Called after every BeginGPURenderPass. A new pass starts with nothing bound,
// so a cache that outlived one would skip binds the GPU never received.
@(private)
bind_cache_reset :: proc() {
	r := &mbi.renderer
	r.bound_pipeline          = nil
	r.bound_texture           = nil
	r.bound_sampler           = nil
	r.bound_quad              = false
	r.bound_joint_buffer      = nil
	r.bound_material_textures = {}
	r.bound_shadow_maps       = {}
	r.bound_cascade_maps      = nil
	r.bound_cube_maps         = nil
	r.bound_probe_maps        = {}
	r.bound_light_buffer      = nil
	r.bound_cluster_ranges        = nil
	r.bound_cluster_light_indices = nil
}

// -----------------------------------------------------------------------
// Frame loop
// -----------------------------------------------------------------------

/*
	Starts a frame: acquires a command buffer and the swapchain image.

	Everything drawn goes between this and `end_drawing`. A frame that cannot
	get a swapchain image -- a minimised window is the usual reason -- is
	skipped rather than failed, and every draw between the two quietly becomes
	a no-op.
*/
begin_drawing :: proc() {
	ensure(mbi.initialized, "matchbox.init must be called before begin_drawing")

	/*
		In pixels, not points.

		The window is created with .HIGH_PIXEL_DENSITY, which asks the platform for
		a backing surface at the display's real resolution -- so on a display at
		125% a 640x480 window has an 800x600 swapchain. This used to read
		GetWindowSize, which reports points, and window_width then disagreed with
		the thing being drawn into.

		Nothing looked broken, which is why it went unnoticed: get_screen_dims feeds
		this to the vertex shader as the divisor, so a full-width rect still
		reached the edge of the window. What was lost was the resolution that was
		asked for -- the whole frame was composed at point resolution and stretched
		over the pixels, so text baked at 32 was drawn across 40 and came out soft.
		For a nearest-filtered pixel image it is worse than soft: one source pixel
		lands on 1.25 screen pixels, and the seams fall in different places down
		the image.
	*/
	sdl.GetWindowSizeInPixels(mbi.window, &mbi.window_width, &mbi.window_height)

	if density := sdl.GetWindowPixelDensity(mbi.window); density > 0 {
		mbi.pixel_density = density
	}

	if !mbi.fixed_res {
		mbi.width  = mbi.window_width
		mbi.height = mbi.window_height
	}

	if mbi.fixed_res {
		scale_x := f32(mbi.window_width)  / f32(mbi.width)
		scale_y := f32(mbi.window_height) / f32(mbi.height)
		mbi.draw_scale = min(scale_x, scale_y)
		scaled_w := f32(mbi.width)  * mbi.draw_scale
		scaled_h := f32(mbi.height) * mbi.draw_scale
		mbi.draw_offset = {
			(f32(mbi.window_width)  - scaled_w) * 0.5,
			(f32(mbi.window_height) - scaled_h) * 0.5,
		}
	} else {
		mbi.draw_scale  = 1
		mbi.draw_offset = {0, 0}
	}

	if .MINIMIZED in sdl.GetWindowFlags(mbi.window) ||
	   mbi.window_width <= 0 || mbi.window_height <= 0 {
		sdl.Delay(16)
	}

	mbi.renderer.pass         = nil
	mbi.renderer.swapchain    = nil
	mbi.renderer.frame_active = false

	// A missing end_clip costs one frame rather than every frame after it.
	clip_reset()

	mbi.renderer.cmd = sdl.AcquireGPUCommandBuffer(mbi.renderer.device)
	if mbi.renderer.cmd == nil do return

	// Blocks until the swapchain has an image free, which is what paces the
	// frame. The old backend did this with a timeline semaphore and a manual
	// count of frames in flight, and then stalled the whole GPU on top of it.
	//
	// A minimized or zero-sized window legitimately hands back nothing. Every
	// draw checks frame_active so the frame quietly does nothing rather than
	// recording into a null pass.
	if !sdl.WaitAndAcquireGPUSwapchainTexture(
		mbi.renderer.cmd, mbi.window, &mbi.renderer.swapchain, nil, nil,
	) {
		return
	}
	if mbi.renderer.swapchain == nil do return

	mbi.renderer.frame_active = true

	// The swapchain is resized by SDL as the window changes, so the explicit
	// resize the old backend needed here is gone.
}

// Ends the frame and hands it to the GPU. Nothing appears on screen until this
// is called.
end_drawing :: proc() {
	r := &mbi.renderer
	if r.cmd == nil do return

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	// Submitted even on a frame that drew nothing: a command buffer that has
	// been acquired has to be handed back one way or another.
	_ = sdl.SubmitGPUCommandBuffer(r.cmd)
	r.cmd          = nil
	r.frame_active = false
}

// Fills the frame with one colour. Call it just after `begin_drawing`: it
// starts a fresh render pass, so anything drawn before it is thrown away.
clear_background :: proc(color: [4]f32 = {0, 0, 0, 1}) {
	r := &mbi.renderer
	if !r.frame_active do return

	// See Renderer.background_color's own comment for who reads this back.
	r.background_color = color

	if r.pass != nil {
		sdl.EndGPURenderPass(r.pass)
		r.pass = nil
	}

	target := sdl.GPUColorTargetInfo{
		texture     = current_color_texture(),
		clear_color = {color[0], color[1], color[2], color[3]},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
	bind_cache_reset()

	// A fresh pass starts with the scissor covering the whole target, so an
	// active clip has to be put back.
	apply_clip()
}

/*
	Opens a render pass if the frame does not have one yet.

	clear_background is the usual way a frame gets its pass, but drawing
	without clearing first is legal, and previously produced a crash rather
	than a picture. This one loads what is already in the swapchain instead of
	clearing it.
*/
@(private)
ensure_pass :: proc() {
	r := &mbi.renderer
	if !r.frame_active || r.pass != nil do return

	target := sdl.GPUColorTargetInfo{
		texture  = current_color_texture(),
		load_op  = .LOAD,
		store_op = .STORE,
	}
	r.pass = sdl.BeginGPURenderPass(r.cmd, &target, 1, nil)
	bind_cache_reset()

	apply_clip()
}

// -----------------------------------------------------------------------
// Basic Shapes
// -----------------------------------------------------------------------

// The middle of a rectangle, which is the point the vertex shader builds the
// quad around. Mirrors draw_sprite: `pivot` is the fraction of the size added
// to `position` to reach the centre.
rect_center :: proc(rectangle: Rectangle) -> [2]f32 {
	return rectangle.position + rectangle.pivot * rectangle.size
}

// The top-left corner. Hit tests and anything laying content out inside a
// rectangle want this, not `position` -- the two are only the same thing when
// the pivot is {0.5, 0.5}.
rect_top_left :: proc(rectangle: Rectangle) -> [2]f32 {
	return rect_center(rectangle) - rectangle.size * 0.5
}

/*
	Whether a point is inside a rectangle.

	Off rect_top_left rather than `position`, so it is right whatever the pivot
	is. The two only agree at pivot {0.5, 0.5}, and testing against `position`
	directly puts the hitbox half a size away from the thing you can see --
	which is a bug that hides until somebody uses a pivot that is not the
	default.

	This is the one hit test. is_mouse_over_rect, is_mouse_over_button,
	is_mouse_over_text_field and is_mouse_over_sprite all come through here.
*/
is_point_in_rect :: proc(point: [2]f32, rectangle: Rectangle) -> bool {
	top_left := rect_top_left(rectangle)
	size     := rectangle.size

	return point.x >= top_left.x && point.x <= top_left.x + size.x &&
	       point.y >= top_left.y && point.y <= top_left.y + size.y
}

// A filled rectangle, rotated about its own pivot. The 2D primitive most of
// `ui.odin` is built from.
draw_rect :: proc(rectangle: Rectangle) {
	ensure_pass()

	vert_data := Vert_Data{
		position = screen_pos(rect_center(rectangle)),
		size     = screen_size(rectangle.size),
		screen   = get_screen_dims(),
		uv_min   = {0, 0},
		uv_max   = {1, 1},
		rotation = rectangle.rotation,
	}

	frag_data := Rect_Frag_Data{color = rectangle.color}

	draw_quad(mbi.renderer.pipelines.rect, &vert_data, &frag_data, size_of(frag_data))
}
