package matchbox

/*
	Sprite_Cache -- the frame guard
	-------------------------------
	The cache hands back pointers, and eviction frees what it drops. Those two
	facts together are why the guard exists: without it a `limit = 1` cache
	freed the sprite it had returned moments earlier, in the same frame, while
	the caller was still holding the pointer and drawing through it.

	These run without a GPU because a zero `Sprite` has no texture and
	`destroy_mesh` nil-guards both the texture and the device, so eviction
	takes the real path rather than a stubbed one.
*/

import "core:testing"

// Two entries asked for in one frame both stay, whatever the limit says.
// Going one over for a frame is the cheaper mistake -- the alternative is
// freeing something being drawn.
@(test)
test_frame_guard_keeps_what_was_handed_out :: proc(t: ^testing.T) {
	mbi.frame = 1

	cache := create_sprite_cache(int, limit = 1)
	defer destroy_sprite_cache(&cache)

	first  := sprite_cache_put(&cache, 1, Sprite{})
	second := sprite_cache_put(&cache, 2, Sprite{})

	testing.expect_value(t, get_sprite_cache_len(&cache), 2)
	testing.expect(t, sprite_cache_find(&cache, 1) == first,
		"the first entry was freed while the caller still held its pointer")
	testing.expect(t, sprite_cache_find(&cache, 2) == second,
		"the second entry did not survive its own insertion")
}

// The extra is collected as soon as the screen stops asking for it, so the
// limit is honoured again on the next frame rather than drifting upward.
@(test)
test_limit_is_honoured_on_the_next_frame :: proc(t: ^testing.T) {
	mbi.frame = 1

	cache := create_sprite_cache(int, limit = 1)
	defer destroy_sprite_cache(&cache)

	sprite_cache_put(&cache, 1, Sprite{})
	sprite_cache_put(&cache, 2, Sprite{})

	mbi.frame = 2
	sprite_cache_put(&cache, 3, Sprite{})

	testing.expect_value(t, get_sprite_cache_len(&cache), 1)
	testing.expect(t, is_sprite_cache_holding(&cache, 3),
		"the most recently used entry should be the one kept")
}

/*
	Before the first poll_events, `mbi.frame` is 0 and so is every `used_on`.

	The guard has to be inert here or it would read every entry as in-use by a
	frame that has not started, and the limit would do nothing at exactly the
	moment a game loads a batch of art during setup.
*/
@(test)
test_guard_is_inert_before_the_first_frame :: proc(t: ^testing.T) {
	mbi.frame = 0

	cache := create_sprite_cache(int, limit = 1)
	defer destroy_sprite_cache(&cache)

	sprite_cache_put(&cache, 1, Sprite{})
	sprite_cache_put(&cache, 2, Sprite{})

	testing.expect_value(t, get_sprite_cache_len(&cache), 1)
}
