package matchbox

/*
	Sprite_Cache
	------------
	Loads a sprite the first time it is asked for, keeps it under a key, and
	gives everything back at teardown.

	Matchbox has create_sprite and destroy_sprite and nothing in between, so a
	game with more art than it wants resident writes this itself. It gets
	written twice, because there are two shapes of it and they look different
	until you put them side by side: a map of everything loaded so far, and a
	single slot that evicts because the full size art is a megabyte an image
	and only one is ever on screen. They are the same cache with a different
	`limit`.

	Keyed by anything comparable -- a string, an enum, an integer id. The key
	is what the game already calls the thing; the path is only how it is found
	on disk the first time.

	Sprites are heap allocated and handed back by pointer, so the pointer stays
	good as more are loaded. A pointer into the map itself would not: Odin's
	map moves its values when it grows.
*/

import "core:log"
import "core:os"

/*
	`limit` is how many sprites may be resident. Zero means no limit, which is
	what a cache of small things wants. One is the single evicting slot.

	Eviction is least-recently-used, counting a hit as a use, so the thing on
	screen is not the thing thrown away.
*/
Sprite_Cache :: struct($Key: typeid) {
	sprites: map[Key]^Sprite,
	order:   [dynamic]Key, // least recently used first
	limit:   int,
}

sprite_cache_make :: proc($Key: typeid, limit: int = 0, allocator := context.allocator) -> Sprite_Cache(Key) {
	return Sprite_Cache(Key){
		sprites = make(map[Key]^Sprite, allocator = allocator),
		order   = make([dynamic]Key, allocator = allocator),
		limit   = limit,
	}
}

/*
	The sprite for `key`, loading it from `path` if this is the first ask.

	Returns nil when the file cannot be read, rather than bringing the game
	down: a missing image is a content problem, and a game that draws nothing
	in that slot is easier to diagnose than one that will not start.

	The result belongs to the cache. Copy it before moving it about -- position
	and rotation live on the sprite, and two callers drawing the same cached
	sprite in two places want two copies, not one they take turns overwriting.
*/
sprite_cache_get :: proc(cache: ^Sprite_Cache($Key), key: Key, path: string, scale: f32 = 1) -> ^Sprite {
	if existing, found := cache.sprites[key]; found {
		sprite_cache_touch(cache, key)
		return existing
	}

	bytes, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.errorf("sprite cache could not read %s: %v", path, err)
		return nil
	}
	defer delete(bytes)

	sprite := new(Sprite)
	sprite^ = create_sprite(bytes, scale)

	cache.sprites[key] = sprite
	append(&cache.order, key)

	// After inserting, not before: evicting first would throw something out to
	// make room and then possibly fail to fill it.
	sprite_cache_trim(cache)

	return sprite
}

// Whether a key is resident, without loading it.
sprite_cache_has :: proc(cache: ^Sprite_Cache($Key), key: Key) -> bool {
	return key in cache.sprites
}

// How many sprites are resident.
sprite_cache_len :: proc(cache: ^Sprite_Cache($Key)) -> int {
	return len(cache.sprites)
}

// Drops one entry. Quietly does nothing when the key is not resident.
sprite_cache_evict :: proc(cache: ^Sprite_Cache($Key), key: Key) {
	sprite, found := cache.sprites[key]
	if !found do return

	destroy_sprite(sprite)
	free(sprite)
	delete_key(&cache.sprites, key)

	for k, i in cache.order {
		if k == key {
			ordered_remove(&cache.order, i)
			break
		}
	}
}

// Frees every sprite and the cache's own storage.
sprite_cache_destroy :: proc(cache: ^Sprite_Cache($Key)) {
	for _, sprite in cache.sprites {
		destroy_sprite(sprite)
		free(sprite)
	}

	delete(cache.sprites)
	delete(cache.order)

	cache.sprites = nil
	cache.order   = nil
}

// Moves a key to the most-recently-used end.
@(private)
sprite_cache_touch :: proc(cache: ^Sprite_Cache($Key), key: Key) {
	for k, i in cache.order {
		if k == key {
			ordered_remove(&cache.order, i)
			append(&cache.order, key)
			return
		}
	}
}

// Evicts from the least-recently-used end until the limit is met.
@(private)
sprite_cache_trim :: proc(cache: ^Sprite_Cache($Key)) {
	if cache.limit <= 0 do return

	for len(cache.order) > cache.limit {
		sprite_cache_evict(cache, cache.order[0])
	}
}
