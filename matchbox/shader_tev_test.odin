#+build windows

package matchbox

import "core:testing"

// The plan mbsc generated for the shipped shader, read as the 3DS reads it
@(test)
reads_the_shipped_mesh_plan :: proc(t:^testing.T) {
	plan, ok, message := parse_tev_plan(#load("shaders/mesh.3ds.tev", string))
	testing.expect(t, ok, message)
	testing.expect_value(t, plan.texture_count, 1)
	testing.expect_value(t, plan.stage_count, 1)

	stage := plan.stages[0]
	testing.expect_value(t, stage.function, Tev_Function.MODULATE)
	testing.expect_value(t, stage.operand_count, 2)
	testing.expect_value(t, stage.operands[0], Tev_Operand{source = .TEXTURE0})
	testing.expect_value(t, stage.operands[1], Tev_Operand{source = .PRIMARY_COLOR})

	testing.expect(t, plan.alpha_test.enabled)
	testing.expect_value(t, plan.alpha_test.function, Tev_Compare.GEQUAL)
	testing.expect_value(t, plan.alpha_test.uniform, "render_alpha_cutoff")

	// the shipped shader doesn't light, so its draws leave the lighting unit off
	testing.expect_value(t, plan.lighting, Tev_Lighting{})
}

// Every part of the format: three sources with one-minus, a literal constant, a literal alpha test
@(test)
reads_every_part_of_the_format :: proc(t:^testing.T) {
	text := "mbs-tev 1\ntarget 3ds\ntexture 0 tex texcoord 0\n" +
		"stage 0 INTERPOLATE TEXTURE0 PRIMARY_COLOR CONSTANT! constant 0.25 0.5 0.75 1\n" +
		"stage 1 ADD PREVIOUS CONSTANT constant uniform bias\n" +
		"alphatest GREATER 0.5\n"
	plan, ok, message := parse_tev_plan(text)
	testing.expect(t, ok, message)
	testing.expect_value(t, plan.stage_count, 2)
	testing.expect_value(t, plan.stages[0].operands[2], Tev_Operand{source = .CONSTANT, one_minus = true})
	testing.expect_value(t, plan.stages[0].constant, [4]f32{0.25, 0.5, 0.75, 1})
	testing.expect_value(t, plan.stages[1].constant_uniform, "bias")
	testing.expect_value(t, plan.alpha_test.function, Tev_Compare.GREATER)
	testing.expect_value(t, plan.alpha_test.reference, 0.5)
}

// A plan the reader cannot apply is refused with the line, never skipped
@(test)
refuses_what_it_does_not_know :: proc(t:^testing.T) {
	cases := [?]string {
		"target 3ds\nstage 0 REPLACE TEXTURE0\n",                       // no header
		"mbs-tev 3\nstage 0 REPLACE TEXTURE0\n",                        // unknown version
		"mbs-tev 1\nstage 0 DOT3_RGB TEXTURE0 PRIMARY_COLOR\n",         // a function mbsc does not emit
		"mbs-tev 1\nstage 0 MODULATE TEXTURE0\n",                       // too few sources
		"mbs-tev 1\nstage 1 REPLACE TEXTURE0\n",                        // out of order
		"mbs-tev 1\nstage 0 REPLACE TEXTURE0\nfog on\n",                // unknown line
		"mbs-tev 1\n",                                                 // no stages
		"mbs-tev 2\nstage 0 REPLACE FRAGMENT_PRIMARY\nlighting\n",             // lighting with no results
		"mbs-tev 2\nstage 0 REPLACE FRAGMENT_PRIMARY\nlighting ambient\n",     // a result the unit doesn't give
		"mbs-tev 2\nstage 0 REPLACE FRAGMENT_PRIMARY\nlighting_table D1 NH\n", // a table not applied yet
		"mbs-tev 2\nstage 0 REPLACE FRAGMENT_PRIMARY\nlighting_two_sided yes\n",
		"mbs-tev 2\nstage 0 REPLACE FRAGMENT_PRIMARY\nlighting_fresnel primary\n",
	}
	for text in cases {
		_, ok, message := parse_tev_plan(text)
		testing.expectf(t, !ok, "accepted: %q", text)
		testing.expect(t, message != "")
	}
}

// The plan mbsc writes for a lit, textured shader with a highlight (tev_test.odin's golden plan, G2 L2)
@(test)
reads_the_lighting_section :: proc(t:^testing.T) {
	text := "mbs-tev 2\ntarget 3ds\n\ntexture 0 a texcoord 0\n\n" +
		"stage 0 MULTIPLY_ADD FRAGMENT_PRIMARY TEXTURE0 FRAGMENT_SECONDARY\n\n" +
		"lighting diffuse specular\nlighting_table D0 NH\nlighting_clamp_highlights true\n" +
		"lighting_two_sided false\nlighting_fresnel none\n"
	plan, ok, message := parse_tev_plan(text)
	testing.expect(t, ok, message)
	testing.expect_value(t, plan.stages[0].operands[0], Tev_Operand{source = .FRAGMENT_PRIMARY})
	testing.expect_value(t, plan.stages[0].operands[2], Tev_Operand{source = .FRAGMENT_SECONDARY})
	want := Tev_Lighting {
		diffuse = true,
		specular = true,
		table = "D0",
		table_input = "NH",
		clamp_highlights = true,
		two_sided = false,
		fresnel = "none",
	}
	testing.expect_value(t, plan.lighting, want)
}
