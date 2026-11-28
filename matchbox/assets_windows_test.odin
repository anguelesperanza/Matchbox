#+build windows

package matchbox

/*
	Listing assets and the loaders that report failure. The listing runs on a folder tree made under the temp directory, with
	mbi's asset paths pointed at it for the test (and put back, under the lock the other tests that write mbi take)
*/

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"

@(private = "file")
make_tree :: proc(root:string, files:[]string) {
	for file in files {
		path := fmt.tprintf("%s%s", root, file)
		last_slash := 0
		for character, index in path do if character == '/' do last_slash = index
		_ = os.make_directory_all(path[:last_slash])
		_ = os.write_entire_file(path, "x")
	}
}

@(test)
asset_names_merge_both_folders_nest_filter_and_sort :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_asset, saved_target := mbi.asset_path, mbi.target_asset_path
	defer mbi.asset_path, mbi.target_asset_path = saved_asset, saved_target

	root := fmt.tprintf("%s/matchbox_asset_names_test/", os.get_env_alloc("TEMP", context.temp_allocator))
	defer os.remove_all(root)
	os.remove_all(root)
	make_tree(root, {
		"shared/models/crate.glb",
		"shared/models/props/barrel.GLB", // upper case, one folder down
		"shared/models/props/notes.txt", // not a model
		"shared/models/both.gltf",
		"pc/models/both.gltf", // in both: listed once
		"pc/models/props/lamp.glb", // only the PC's
	})
	mbi.asset_path = fmt.tprintf("%sshared/", root)
	mbi.target_asset_path = fmt.tprintf("%spc/", root)

	names := get_asset_names(.MODEL, {".glb", ".gltf"})
	testing.expect_value(t, len(names), 4)
	if len(names) == 4 {
		testing.expect_value(t, names[0], "both.gltf")
		testing.expect_value(t, names[1], "crate.glb")
		testing.expect_value(t, names[2], "props/barrel.GLB")
		testing.expect_value(t, names[3], "props/lamp.glb")
	}

	// With no filter the note is there too
	testing.expect_value(t, len(get_asset_names(.MODEL)), 5)

	// A kind with no folder has no assets, and is not an error
	testing.expect_value(t, len(get_asset_names(.AUDIO)), 0)
}

@(test)
checked_loaders_say_no_and_do_not_stop :: proc(t:^testing.T) {
	defer free_all(context.temp_allocator)
	sync.mutex_lock(&mbi_lock)
	defer sync.mutex_unlock(&mbi_lock)
	saved_asset, saved_target := mbi.asset_path, mbi.target_asset_path
	defer mbi.asset_path, mbi.target_asset_path = saved_asset, saved_target

	root := fmt.tprintf("%s/matchbox_checked_loaders_test/", os.get_env_alloc("TEMP", context.temp_allocator))
	defer os.remove_all(root)
	os.remove_all(root)
	make_tree(root, {"shared/images/not_a_picture.png"}) // a file named like an image whose bytes are not one
	mbi.asset_path = fmt.tprintf("%sshared/", root)
	mbi.target_asset_path = fmt.tprintf("%spc/", root)

	_, ok := load_texture_checked("missing.png")
	testing.expect(t, !ok, "a missing texture was ok")
	_, ok = load_texture_checked("not_a_picture.png")
	testing.expect(t, !ok, "bytes that are not a picture were ok")

	_, ok = load_skybox_panorama_checked("missing.png")
	testing.expect(t, !ok, "a missing panorama was ok")
	_, ok = load_skybox_panorama_checked("not_a_picture.png")
	testing.expect(t, !ok, "a bad panorama was ok")
	_, ok = load_skybox_cubemap_checked("missing.png")
	testing.expect(t, !ok, "a missing cube map was ok")
	_, ok = load_skybox_cubemap_checked("not_a_picture.png")
	testing.expect(t, !ok, "a bad cube map was ok")
}
