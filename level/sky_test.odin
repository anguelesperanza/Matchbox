package level

/*
	The sky, without a GPU
	----------------------
	What can be checked without a window: that a sky survives a save and a
	load, that a tint nobody set reads as white rather than black, and that
	setting the path twice does not leave the level holding memory it does not
	own. Loading the texture itself needs a GPU and is checked in the editor.
*/

import "core:testing"

@(test)
test_a_sky_survives_a_save_and_a_load :: proc(t: ^testing.T) {
	built := create_level()
	defer destroy_level(&built)

	set_level_sky(&built, .PANORAMA, "assets/sky/dusk.png")
	built.settings.sky.tint = {0.8, 0.7, 1, 1}

	data, marshal_err := marshal_level(built, allocator = context.temp_allocator)
	testing.expectf(t, marshal_err == nil, "marshal: %v", marshal_err)

	read, problems, unmarshal_err := unmarshal_level(data, context.temp_allocator)
	defer delete_problems(problems)
	testing.expectf(t, unmarshal_err == nil, "unmarshal: %v", unmarshal_err)

	testing.expect_value(t, read.settings.sky.kind, Sky_Kind.PANORAMA)
	testing.expect_value(t, read.settings.sky.path, "assets/sky/dusk.png")
	testing.expect_value(t, read.settings.sky.tint, [4]f32{0.8, 0.7, 1, 1})

	// The kind is written as its name, so reordering the enum cannot silently
	// turn a panorama into a cube map.
	testing.expect(t, contains(string(data), "\"PANORAMA\""), "the kind is written as a name")
}

// A level written before there were skies has no sky key at all, and a zeroed
// tint. Neither may turn into a black sky over everything.
@(test)
test_a_level_without_a_sky_reads_as_having_none :: proc(t: ^testing.T) {
	text := `{"version": 1, "settings": {"background": [0, 0, 0, 1]}, "entities": []}`

	read, problems, err := unmarshal_level(transmute([]byte)text, context.temp_allocator)
	defer delete_problems(problems)
	testing.expectf(t, err == nil, "unmarshal: %v", err)

	testing.expect_value(t, read.settings.sky.kind, Sky_Kind.NONE)
	testing.expect_value(t, read.settings.sky.path, "")
	testing.expect_value(t, sky_tint(read.settings.sky), SKY_DEFAULT_TINT)

	// And a sky that was set but never tinted is the image as it comes, not
	// black.
	read.settings.sky.kind = .CUBEMAP
	testing.expect_value(t, sky_tint(read.settings.sky), SKY_DEFAULT_TINT)

	read.settings.sky.tint = {0.5, 0.5, 0.5, 1}
	testing.expect_value(t, sky_tint(read.settings.sky), [4]f32{0.5, 0.5, 0.5, 1})
}

/*
	`set_level_sky` takes a copy, and keeps the old one when the text is the
	same -- which is what makes handing the level its own path back safe. The
	test matters because the level frees this string in `destroy_level`: a path
	assigned directly from somewhere else would be freed twice.
*/
@(test)
test_setting_the_sky_path_owns_its_copy :: proc(t: ^testing.T) {
	level := create_level()
	defer destroy_level(&level)

	set_level_sky(&level, .CUBEMAP, "assets/sky/cross.png")
	first := raw_data(level.settings.sky.path)

	// The same text again: the level keeps the string it already has.
	set_level_sky(&level, .PANORAMA, "assets/sky/cross.png")
	testing.expect(t, raw_data(level.settings.sky.path) == first, "the same path should not be copied again")
	testing.expect_value(t, level.settings.sky.kind, Sky_Kind.PANORAMA)

	// Its own path handed back in, which must not free what it then copies.
	set_level_sky(&level, .PANORAMA, level.settings.sky.path)
	testing.expect_value(t, level.settings.sky.path, "assets/sky/cross.png")

	// A different path replaces it, and none empties it.
	set_level_sky(&level, .PANORAMA, "assets/sky/noon.png")
	testing.expect_value(t, level.settings.sky.path, "assets/sky/noon.png")

	set_level_sky(&level, .NONE, "")
	testing.expect_value(t, level.settings.sky.path, "")
	testing.expect_value(t, level.settings.sky.kind, Sky_Kind.NONE)
}

@(private)
contains :: proc(text, part: string) -> bool {
	if len(part) > len(text) do return false
	outer: for start in 0 ..= len(text) - len(part) {
		for i in 0 ..< len(part) {
			if text[start + i] != part[i] do continue outer
		}
		return true
	}
	return false
}
