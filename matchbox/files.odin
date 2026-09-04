package matchbox

/*
	Files
	-----
	Reading what a game ships with, and writing what it saves.

	These go through SDL rather than `core:os`, and the reason is Android. There,
	the things a game ships with are not files: they are entries inside the apk,
	and nothing that opens a path can see them. SDL's IOStream knows that and
	routes a relative path to the asset manager, so the same `"art/ember.png"`
	that opens a file on a desktop opens an asset on a phone.

	It costs nothing anywhere else. On Windows, macOS and Linux this is an
	ordinary open-and-read that happens to be spelled through SDL, and `core:os`
	is still perfectly good for a game's own files -- a config, a save, a level
	the player made. The distinction worth holding on to is:

	  shipped with the game   -> read_entire_file, so it works inside an apk
	  made by the player      -> get_pref_path, and core:os is fine

	Which is also why writing is separate and does not take an arbitrary path.
	There is nowhere on Android a program may simply write to; it gets a
	directory of its own and that is all. get_pref_path is that directory, and on a
	desktop it is the equivalent -- AppData, Application Support, .local/share --
	rather than the working directory, which is wherever a shortcut happened to
	start the program.
*/

import "core:log"
import "core:strings"

import sdl "vendor:sdl3"

/*
	Reads a whole file into memory.

	`path` is relative to wherever the game's data lives: the working directory
	on a desktop, and the apk's assets on Android. An absolute path still works
	on a desktop and is meaningless on Android, so anything shipped with the game
	should be asked for by a relative path.

	Returns ok = false and logs rather than panicking. A file that will not open
	is a content problem, and every caller here already has something sensible to
	do about it -- the sprite cache draws nothing, the image loader reports it.

	The bytes are copied into `allocator` so they are freed with `delete` like
	anything else, rather than handed back as SDL's allocation with a rule about
	which free to call.
*/
read_entire_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)

	size: uint
	loaded := sdl.LoadFile(c_path, &size)
	if loaded == nil {
		log.errorf("could not read %s: %s", path, sdl.GetError())
		return nil, false
	}
	defer sdl.free(loaded)

	// A real file of no bytes is not an error, and neither is an empty asset.
	if size == 0 do return nil, true

	data = make([]byte, int(size), allocator)
	copy(data, (cast([^]byte)loaded)[:size])

	return data, true
}

/*
	The one directory a game may write to, created if it is not there.

	`org` and `app` name it -- on Windows that is under AppData, on Android it is
	the app's own internal storage, which is the only place there is. Ends with a
	separator, so a filename can be joined straight on:

		dir := matchbox.get_pref_path("Bramble", "Cards")
		defer delete(dir)
		os.write_entire_file(fmt.tprintf("%ssave.json", dir), bytes)

	Returns "" when SDL cannot provide one, which a caller should treat as "this
	machine has nowhere for me to save" rather than falling back to the working
	directory -- on a phone that fallback is not writable, and on a desktop it is
	wherever a shortcut happened to start the program.

	The result is the caller's to delete.
*/
get_pref_path :: proc(org: string, app: string, allocator := context.allocator) -> string {
	c_org := strings.clone_to_cstring(org, context.temp_allocator)
	c_app := strings.clone_to_cstring(app, context.temp_allocator)

	raw := sdl.GetPrefPath(c_org, c_app)
	if raw == nil {
		log.errorf("no writable directory available: %s", sdl.GetError())
		return ""
	}
	defer sdl.free(raw)

	return strings.clone(string(cstring(raw)), allocator)
}

/*
	Where the program itself lives, ending with a separator.

	For finding data shipped beside an executable when the working directory is
	not it, which is what happens whenever somebody starts a game from a
	shortcut. Empty on Android, deliberately: there is no such place, and the
	answer there is to ship the data as assets and read them with
	read_entire_file.

	The result is the caller's to delete.
*/
get_base_path :: proc(allocator := context.allocator) -> string {
	raw := sdl.GetBasePath()
	if raw == nil do return ""

	return strings.clone(string(raw), allocator)
}
