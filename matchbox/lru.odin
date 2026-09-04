package matchbox

/*
	Lru_Cache
	---------
	The mechanism behind both caches in Matchbox: a map of what is resident, the
	order it was last asked for, and the rule about what may be thrown away.

	`Sprite_Cache` and the font cache were the same structure written twice --
	the same map beside the same `[dynamic]` order list, and a `touch` that was
	line-for-line identical in both. Only one of them had learned the lesson
	below about the frame guard, which is the reason unifying them was worth
	doing rather than merely tidy.

	**The map and the order list are one thing.** The map answers "have we got
	this", the list answers "which goes first when we are over the limit", and
	neither is meaningful without the other -- so they live in one struct and
	are only ever written through the procedures here.

	What is deliberately *not* here is policy. Where the limit comes from and
	how a value is freed differ between the two callers -- one takes a limit
	from the game and holds sprites, the other reads a constant and holds font
	atlases -- so those arrive as arguments rather than being baked in. That
	also keeps a zero-valued cache usable without a constructor, which is what
	lets the font cache sit on `mbi` as a plain field.

	Values are heap allocated and handed back by pointer, so a pointer stays
	good as more are loaded. A pointer into the map itself would not: Odin's map
	moves its values when it grows.
*/

// One resident value, and the frame it was last handed out on. The frame
// number is what makes the guard in `lru_trim` possible.
Lru_Entry :: struct($Value: typeid) {
	value:   ^Value,
	used_on: u64,
}

Lru_Cache :: struct($Key: typeid, $Value: typeid) {
	entries: map[Key]Lru_Entry(Value),
	order:   [dynamic]Key, // least recently used first
}

// The value under a key, or nil, counting the ask as a use so that what is
// being looked at is not what gets thrown away.
@(private)
lru_get :: proc(cache: ^Lru_Cache($Key, $Value), key: Key) -> ^Value {
	entry, found := cache.entries[key]
	if !found do return nil

	entry.used_on   = mbi.frame
	cache.entries[key] = entry
	lru_touch(cache, key)

	return entry.value
}

// Takes ownership of `value` under `key`. The caller trims afterwards rather
// than here, because only the caller knows its own limit.
@(private)
lru_put :: proc(cache: ^Lru_Cache($Key, $Value), key: Key, value: ^Value) {
	cache.entries[key] = Lru_Entry(Value){value = value, used_on = mbi.frame}
	append(&cache.order, key)
}

@(private)
lru_has :: proc(cache: ^Lru_Cache($Key, $Value), key: Key) -> bool {
	return key in cache.entries
}

@(private)
lru_len :: proc(cache: ^Lru_Cache($Key, $Value)) -> int {
	return len(cache.entries)
}

// Moves a key to the most-recently-used end.
@(private)
lru_touch :: proc(cache: ^Lru_Cache($Key, $Value), key: Key) {
	for k, i in cache.order {
		if k == key {
			ordered_remove(&cache.order, i)
			append(&cache.order, key)
			return
		}
	}
}

// Drops one entry, freeing it through `destroy_value`. Quietly does nothing
// when the key is not resident.
@(private)
lru_evict :: proc(cache: ^Lru_Cache($Key, $Value), key: Key, destroy_value: proc(value: ^Value)) {
	entry, found := cache.entries[key]
	if !found do return

	destroy_value(entry.value)
	free(entry.value)
	delete_key(&cache.entries, key)

	for k, i in cache.order {
		if k == key {
			ordered_remove(&cache.order, i)
			break
		}
	}
}

/*
	Evicts from the least-recently-used end until `limit` is met. A `limit` of
	zero or less means no limit at all.

	**Stops at anything used during the current frame, whatever the limit
	says.** A screen drawing seven font sizes would otherwise free the atlas
	belonging to a pointer it handed out moments earlier and is still drawing
	through -- the cache doing exactly what it was told, and the game reading a
	released texture. The same holds for a one-slot sprite cache asked for two
	sprites in a frame. Going one over the limit for a frame is the cheaper
	mistake, and the extra is collected as soon as the screen stops asking.

	`mbi.frame > 0` matters and is not a nil-check in disguise: the frame
	counter is 0 until the first `poll_events`, and so is every `used_on`
	recorded before then. Without it, everything loaded during setup looks like
	it is in use by the frame that has not started yet, and the limit does
	nothing at exactly the moment a game is most likely to ask for a dozen
	things at once.
*/
@(private)
lru_trim :: proc(cache: ^Lru_Cache($Key, $Value), limit: int, destroy_value: proc(value: ^Value)) {
	if limit <= 0 do return

	for len(cache.order) > limit {
		oldest := cache.order[0]

		if entry, found := cache.entries[oldest]; found {
			if mbi.frame > 0 && entry.used_on == mbi.frame do return

			destroy_value(entry.value)
			free(entry.value)
			delete_key(&cache.entries, oldest)
		}

		ordered_remove(&cache.order, 0)
	}
}

// Frees every value and the cache's own storage.
@(private)
lru_destroy :: proc(cache: ^Lru_Cache($Key, $Value), destroy_value: proc(value: ^Value)) {
	for _, entry in cache.entries {
		destroy_value(entry.value)
		free(entry.value)
	}

	delete(cache.entries)
	delete(cache.order)

	cache.entries = nil
	cache.order   = nil
}
