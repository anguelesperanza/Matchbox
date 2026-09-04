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

	The map, the order list and the eviction rule are `Lru_Cache` in `lru.odin`,
	shared with the font cache. What lives here is the policy: sprites are what
	is held, `limit` is where the ceiling comes from, and `destroy_sprite` is
	how one is given back.
*/

import "core:log"

/*
	`limit` is how many sprites may be resident. Zero means no limit, which is
	what a cache of small things wants. One is the single evicting slot.

	Eviction is least-recently-used, counting a hit as a use, so the thing on
	screen is not the thing thrown away.

	**A limit is a ceiling between frames, not within one.** Nothing asked for
	during the current frame is ever evicted, so a `limit = 1` cache asked for
	two sprites in one frame holds both until the next -- see `lru_trim`. That
	is deliberate: the alternative is freeing a sprite whose pointer the caller
	is still holding and about to draw through.
*/
Sprite_Cache :: struct($Key: typeid) {
	using lru: Lru_Cache(Key, Sprite),
	limit:     int,
}

/*
	A cache that loads each image once and hands the same sprite to everyone who
	asks for it, keyed by whatever a game already identifies its art by.

	`limit` of zero means no eviction: the cache grows to hold every image asked
	for and frees them together. A non-zero limit evicts least-recently-used,
	which is what a game streaming a large atlas set wants.
*/
create_sprite_cache :: proc($Key: typeid, limit: int = 0, allocator := context.allocator) -> Sprite_Cache(Key) {
	cache: Sprite_Cache(Key)
	cache.entries = make(map[Key]Lru_Entry(Sprite), allocator = allocator)
	cache.order   = make([dynamic]Key, allocator = allocator)
	cache.limit   = limit
	return cache
}

/*
	The sprite for `key`, loading it from `path` if this is the first ask.

	Returns nil when the file cannot be read, rather than bringing the game
	down: a missing image is a content problem, and a game that draws nothing
	in that slot is easier to diagnose than one that will not start.

	The result belongs to the cache. Copy it before moving it about -- position
	and rotation live on the sprite, and two callers drawing the same cached
	sprite in two places want two copies, not one they take turns overwriting.

	The pointer itself is good for the frame it was asked in: the cache will not
	evict something it handed out this frame, however small the limit.
*/
sprite_cache_get :: proc(cache: ^Sprite_Cache($Key), key: Key, path: string, scale: f32 = 1) -> ^Sprite {
	if existing := lru_get(&cache.lru, key); existing != nil {
		return existing
	}

	// Through SDL rather than core:os, so `path` reaches an apk's assets on
	// Android as well as a file on a desktop. read_entire_file has already
	// logged whatever went wrong.
	bytes, ok := read_entire_file(path, context.allocator)
	if !ok do return nil
	defer delete(bytes)

	sprite := new(Sprite)
	sprite^ = create_sprite(bytes, scale)

	lru_put(&cache.lru, key, sprite)

	// After inserting, not before: evicting first would throw something out to
	// make room and then possibly fail to fill it.
	lru_trim(&cache.lru, cache.limit, destroy_sprite)

	return sprite
}

/*
	Puts a sprite the game made itself into the cache, under a key.

	sprite_cache_get loads from a path, which is most of what a cache is for and
	is no use to a sprite that was composited rather than loaded -- there is no
	file to name. This is the other door into the same cache: the sprite is
	handed over, the cache owns it from then on, and everything else -- the
	limit, the eviction order, the teardown -- works as it does for a loaded one.

	Replaces whatever was under that key, destroying it, so this is also how a
	game redraws something that has changed.
*/
sprite_cache_put :: proc(cache: ^Sprite_Cache($Key), key: Key, sprite: Sprite) -> ^Sprite {
	sprite_cache_evict(cache, key)

	held := new(Sprite)
	held^ = sprite

	lru_put(&cache.lru, key, held)
	lru_trim(&cache.lru, cache.limit, destroy_sprite)

	return held
}

/*
	The sprite under a key, or nil, without loading anything.

	sprite_cache_get takes a path because a cache was originally a way of not
	loading the same file twice. A game that fills its cache with
	sprite_cache_put has no path to offer and no file to fall back on -- asking
	for one it made itself should not require naming a file that does not exist.

	Counts as a use, so what is asked for is not what gets evicted.
*/
sprite_cache_find :: proc(cache: ^Sprite_Cache($Key), key: Key) -> ^Sprite {
	return lru_get(&cache.lru, key)
}

// Whether a key is resident, without loading it.
is_sprite_cache_holding :: proc(cache: ^Sprite_Cache($Key), key: Key) -> bool {
	return lru_has(&cache.lru, key)
}

// How many sprites are resident.
get_sprite_cache_len :: proc(cache: ^Sprite_Cache($Key)) -> int {
	return lru_len(&cache.lru)
}

// Drops one entry. Quietly does nothing when the key is not resident.
sprite_cache_evict :: proc(cache: ^Sprite_Cache($Key), key: Key) {
	lru_evict(&cache.lru, key, destroy_sprite)
}

// Frees every sprite and the cache's own storage.
destroy_sprite_cache :: proc(cache: ^Sprite_Cache($Key)) {
	lru_destroy(&cache.lru, destroy_sprite)
}
