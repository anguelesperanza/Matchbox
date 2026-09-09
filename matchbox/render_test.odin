package matchbox

/*
	Sampler-budget regression
	--------------------------
	`lighting_rework.md` section 7.7: P3's mesh fragment shader declared 20
	sampled textures and 20 samplers, above Vulkan's guaranteed per-stage
	floor of 16 for both `maxPerStageDescriptorSampledImages` and
	`maxPerStageDescriptorSamplers` -- invisible to `odin check`, invisible to
	`dxc`, and untestable by rendering a frame in this environment (no GPU).
	P3b collapsed CASCADED's and CUBE's own resource arrays into one
	Texture2DArray apiece, bringing the count to 8; P4's environment probe
	added its own two maps (`irradiance_map`/`prefiltered_map`,
	mesh.frag.hlsl) on top of that, bringing it to 10 -- see mesh.frag.hlsl's
	own top comment and `MESH_FRAG_SAMPLER_COUNT`'s (render.odin).

	This is the one number that can be pinned without a device: it is a plain
	Odin constant, passed to `CreateGPUShader` by `init` rather than a bare
	literal at that call site, specifically so a test can read the actual
	value the code sends rather than asserting on source text. A future phase
	that pushes this back toward or past 16 -- a real BRDF integration LUT
	texture would have been the next candidate, had P4 not approximated that
	term analytically instead (`pbr_env_brdf_approx`, brdf/pbr_common.hlsli)
	-- will fail here before it ever reaches a device that enforces the
	limit -- which, per `lighting_rework.md`'s own account, is exactly the
	class of failure nothing else in this package's toolchain catches.
*/

import "core:testing"

@(test)
test_mesh_frag_sampler_count_is_pinned_under_vulkan_floor :: proc(t: ^testing.T) {
	// The value itself, not just the inequality below -- so an accidental
	// change (not just a regression past the floor) shows up as a failing
	// test a developer has to look at and consciously update, the same
	// "changing the expected value is itself the finding" shape
	// shadow_test.odin's own numeric expectations already have. P4 is
	// exactly that: this failed with "expected 8, got 10" the moment the
	// environment probe's two maps were declared, and updating it here is
	// that conscious look, not a rubber stamp.
	//
	// P7b did it again -- "expected 10, got 11", for the ambient-occlusion
	// texture lighting_core.hlsli declares for this shader and the deferred
	// lighting pass alike (ssao.odin). Looked at and accepted: 11 is four
	// under the floor the second assertion below checks, and the sampler
	// carries with it the renumbering of every storage buffer behind it,
	// which is the part worth having a test insist somebody notices.
	testing.expect_value(t, MESH_FRAG_SAMPLER_COUNT, 11)

	// The actual invariant: Vulkan's spec-guaranteed minimum for both
	// maxPerStageDescriptorSampledImages and maxPerStageDescriptorSamplers is
	// 16 (lighting_rework.md section 7.7) -- a device sitting at that floor,
	// which this package's own Android target makes an ordinary case rather
	// than a corner one, fails at shader or pipeline creation the moment this
	// shader's declared count reaches it.
	testing.expect(
		t, MESH_FRAG_SAMPLER_COUNT < 16,
		"mesh fragment shader sampler count must stay under Vulkan's guaranteed per-stage floor of 16 (maxPerStageDescriptorSampledImages / maxPerStageDescriptorSamplers)",
	)
}
