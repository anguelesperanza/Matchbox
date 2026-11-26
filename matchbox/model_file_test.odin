#+build windows

package matchbox

import "core:testing"

/*What the PC reads from glTF, written as a .mbm and read back, is the same model the handhelds get*/
@(test)
a_model_file_reads_back_what_was_written :: proc(t:^testing.T) {
	original, ok := read_gltf_model("tools/testdata/models/test_crate.glb")
	defer destroy_model_data(original)
	if testing.expect(t, ok) == false do return

	names := []string{"models/test_crate_0.png"}
	bytes := write_model_file(original, names)
	defer delete(bytes)
	testing.expect_value(t, string(bytes[:4]), "MBM1")

	copy, copy_ok, problem := read_model_file(bytes)
	defer destroy_model_data(copy)
	if testing.expectf(t, copy_ok, "did not read back: %s", problem) == false do return

	testing.expect_value(t, copy.bounds_min, original.bounds_min)
	testing.expect_value(t, copy.bounds_max, original.bounds_max)
	if testing.expect_value(t, len(copy.image_names), 1) do testing.expect_value(t, copy.image_names[0], "models/test_crate_0.png")
	if testing.expect_value(t, len(copy.parts), len(original.parts)) == false do return
	for part, index in original.parts {
		read := copy.parts[index]
		testing.expect_value(t, read.color, part.color)
		testing.expect_value(t, read.image, part.image)
		testing.expect_value(t, read.blend, part.blend)
		testing.expect_value(t, read.cull, part.cull)
		testing.expect_value(t, read.alpha_cutoff, part.alpha_cutoff)
		testing.expect_value(t, read.material, part.material)
		if testing.expect_value(t, len(read.vertices), len(part.vertices)) {
			for vertex, v in part.vertices do testing.expect_value(t, read.vertices[v], vertex)
		}
		if testing.expect_value(t, len(read.indices), len(part.indices)) {
			for value, i in part.indices do testing.expect_value(t, read.indices[i], value)
		}
	}
	free_all(context.temp_allocator)
}

/*A file cut short anywhere, or one that isn't a model, is refused rather than read as garbage*/
@(test)
a_short_or_foreign_model_file_is_refused :: proc(t:^testing.T) {
	original, ok := read_gltf_model("tools/testdata/models/test_crate.glb")
	defer destroy_model_data(original)
	if testing.expect(t, ok) == false do return
	bytes := write_model_file(original, []string{"models/test_crate_0.png"})
	defer delete(bytes)

	for length := 0; length < len(bytes); length += 7 {
		data, short_ok, _ := read_model_file(bytes[:length])
		testing.expectf(t, short_ok == false, "a file cut to %v of %v bytes was read", length, len(bytes))
		destroy_model_data(data)
	}
	not_a_model := []u8{'P', 'N', 'G', 0, 1, 0, 0, 0}
	_, not_a_model_ok, _ := read_model_file(not_a_model)
	testing.expect(t, not_a_model_ok == false)
	free_all(context.temp_allocator)
}

/*A skinned model's skeleton, clips and cut parts survive the file the handhelds read (G6: .mbm version 3)*/
@(test)
a_skinned_model_file_reads_back_its_skeleton_clips_and_parts :: proc(t:^testing.T) {
	for path in ([?]string{"tools/testdata/models/test_arm.glb", "tools/testdata/models/test_rope.glb"}) {
		// The rope with the 3DS's limit, so there are several parts each with a joint map of its own
		original, ok := read_gltf_model(path, 22)
		defer destroy_model_data(original)
		if testing.expect(t, ok) == false do continue
		bytes := write_model_file(original, nil)
		defer delete(bytes)

		copy, copy_ok, problem := read_model_file(bytes)
		defer destroy_model_data(copy)
		if testing.expectf(t, copy_ok, "%s did not read back: %s", path, problem) == false do continue

		testing.expect_value(t, len(copy.skeleton.rest), len(original.skeleton.rest))
		testing.expect_value(t, len(copy.skeleton.skins), len(original.skeleton.skins))
		testing.expect_value(t, len(copy.animations), len(original.animations))
		for clip, index in original.animations {
			testing.expect_value(t, copy.animations[index].name, clip.name)
			testing.expect_value(t, copy.animations[index].duration, clip.duration)
			testing.expect_value(t, len(copy.animations[index].tracks), len(clip.tracks))
		}
		for node in 0 ..< len(original.skeleton.rest) {
			testing.expect_value(t, copy.skeleton.rest[node], original.skeleton.rest[node])
			testing.expect_value(t, copy.skeleton.parents[node], original.skeleton.parents[node])
			testing.expect_value(t, copy.skeleton.names[node], original.skeleton.names[node])
		}
		if testing.expect_value(t, len(copy.parts), len(original.parts)) == false do continue
		for part, index in original.parts {
			read := copy.parts[index]
			testing.expect_value(t, read.mesh_node, part.mesh_node)
			testing.expect_value(t, len(read.joint_map), len(part.joint_map))
			if testing.expect_value(t, len(read.skinned_vertices), len(part.skinned_vertices)) {
				for vertex, v in part.skinned_vertices do testing.expect_value(t, read.skinned_vertices[v], vertex)
			}
		}

		// Cut short anywhere, even in the skeleton at the end, it is refused
		for length := 0; length < len(bytes); length += 13 {
			short, short_ok, _ := read_model_file(bytes[:length])
			testing.expectf(t, short_ok == false, "%s cut to %v of %v bytes was read", path, length, len(bytes))
			destroy_model_data(short)
		}
	}
	free_all(context.temp_allocator)
}
