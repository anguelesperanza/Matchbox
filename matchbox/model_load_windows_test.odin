#+build windows

package matchbox

import "core:testing"

/*
	tools/testdata/models/test_crate.gltf and .glb, written by tools/make_test_model.py: a textured cube
	(node "crate") with a child node "flag" moved up 1 and scaled 0.5, holding a red quad with a
	double-sided MASK material. The two files hold the same model, the image once as a base64
	URI and once as a buffer view, so both of glTF's ways of carrying an image are read
*/
@(private = "file")
expect_test_crate :: proc(t:^testing.T, path:string) {
	data, ok := read_gltf_model(path)
	defer destroy_model_data(data)
	if testing.expectf(t, ok, "%s did not read", path) == false do return
	if testing.expect_value(t, len(data.parts), 2) == false do return

	crate := data.parts[0]
	testing.expect_value(t, len(crate.vertices), 24)
	testing.expect_value(t, len(crate.indices), 36)
	testing.expect_value(t, crate.image, 0)
	testing.expect_value(t, crate.color, [4]f32{1, 1, 1, 1})
	testing.expect_value(t, crate.cull, Cull_Mode.BACK)
	testing.expect_value(t, crate.blend, Blend_Mode.NONE)
	testing.expect_value(t, crate.alpha_cutoff, 0)

	// The flag's node transform is baked into its vertices: the quad's corner (-0.5, -0.5, 0)
	// lands at 0.5 * corner + (0, 1, 0)
	flag := data.parts[1]
	testing.expect_value(t, len(flag.vertices), 4)
	testing.expect_value(t, flag.vertices[0].position, [3]f32{-0.25, 0.75, 0})
	testing.expect_value(t, flag.vertices[2].position, [3]f32{0.25, 1.25, 0})
	testing.expect_value(t, flag.vertices[0].color, [4]f32{1, 0, 0, 1}) // normalised bytes
	testing.expect_value(t, flag.normals[0], [3]f32{0, 0, 1})
	testing.expect_value(t, flag.image, -1)
	testing.expect_value(t, flag.color, [4]f32{0.5, 1, 1, 1})
	testing.expect_value(t, flag.cull, Cull_Mode.NONE)
	testing.expect_value(t, flag.alpha_cutoff, 0.3)
	if testing.expect_value(t, len(flag.indices), 6) {
		testing.expect_value(t, [6]u16{flag.indices[0], flag.indices[1], flag.indices[2], flag.indices[3], flag.indices[4], flag.indices[5]}, [6]u16{0, 1, 2, 0, 2, 3})
	}

	// One image, the PNG itself
	if testing.expect_value(t, len(data.images), 1) {
		testing.expect_value(t, string(data.images[0][1:4]), "PNG")
	}
	testing.expect_value(t, data.bounds_min, [3]f32{-0.5, -0.5, -0.5})
	testing.expect_value(t, data.bounds_max, [3]f32{0.5, 1.25, 0.5})
}

@(test)
a_gltf_with_embedded_data_reads_as_its_numbers_say :: proc(t:^testing.T) {
	expect_test_crate(t, "tools/testdata/models/test_crate.gltf")
	free_all(context.temp_allocator)
}

@(test)
a_glb_reads_the_same_as_its_gltf :: proc(t:^testing.T) {
	expect_test_crate(t, "tools/testdata/models/test_crate.glb")
	free_all(context.temp_allocator)
}

@(test)
a_missing_model_file_is_not_ok :: proc(t:^testing.T) {
	_, ok := read_gltf_model("tools/testdata/models/no_such_model.glb")
	testing.expect(t, ok == false)
}
