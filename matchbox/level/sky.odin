package level

/*
	The sky
	-------
	A level's skybox: which image is behind everything, and what it is tinted.
	Stargate's `level_editor_plan.md` section 5.19 is the design.

	**In the level, not in the editor.** An outdoor area is built against its
	sky -- how a roofline reads, how far a hill has to be to sit under the
	horizon -- so a sky that lived only in the editor would be a backdrop that
	lies about the game. It is a level setting, saved in the file, and
	`draw_level_sky` is the same call in the editor and in a game.

	**Two source formats, because Matchbox has two** (skybox.odin): a 2:1
	equirectangular panorama, and six faces packed into a 4x3 cross. Which one
	a file is cannot be told from its extension -- both are a `.png` -- so the
	level says which, rather than the loader guessing from an aspect ratio that
	a cropped panorama would get wrong.

	**The texture is loaded where a GPU is, like a model.** `load_level_sky`
	is safe to call every frame: it reloads only when the path or the kind has
	changed, so the editor can call it after the inspector has been edited and
	a game can call it once.
*/

import "core:log"
import "core:strings"

import mb ".."

Sky_Kind :: enum {
	NONE,     // no sky: the background colour, as before there was one
	PANORAMA, // one 2:1 equirectangular image
	CUBEMAP,  // six square faces in a 4x3 cross
}

/*
	A level's sky.

	`tint` multiplies the image on the way out -- the cheap way to take a sky
	toward dusk without a second file. It is left at `{0, 0, 0, 0}` in a level
	that has never set one, and read as white: a zero tint would make every sky
	loaded from an older file black, and "never set" has to mean "as the file
	has it".
*/
Sky_Settings :: struct {
	kind: Sky_Kind,
	path: string, // relative to the project root, with forward slashes
	tint: [4]f32,
}

// What a sky with no tint of its own is drawn at: the image as it comes.
SKY_DEFAULT_TINT :: [4]f32{1, 1, 1, 1}

/*
	What the level holds for its sky while it is in use, and never writes.

	The path and kind that were loaded are kept beside the texture so
	`load_level_sky` can tell "already loaded" from "changed since": the
	settings alone cannot say, since they are what changed. `failed` is the
	same idea for a file that will not load -- without it a bad path would be
	retried, and logged, sixty times a second.
*/
Sky_Runtime :: struct {
	skybox: mb.Skybox,
	path:   string,
	kind:   Sky_Kind,
	failed: bool,
	loaded: bool,
}

/*
	Loads the level's sky if it is not the one already loaded, and releases the
	one it replaces. True when a sky is loaded and ready to draw.

	Needs a GPU. Call it in a frame, beside `load_level_models`.
*/
load_level_sky :: proc(level: ^Level) -> bool {
	sky := &level.settings.sky
	rt  := &level.runtime.sky

	// Already the one asked for: loaded, or already known not to load. Either
	// way there is nothing to do this frame.
	if rt.loaded && rt.kind == sky.kind && rt.path == sky.path {
		return !rt.failed && rt.skybox.texture != nil
	}

	unload_level_sky(level)

	rt.loaded = true
	rt.kind   = sky.kind
	rt.path   = strings.clone(sky.path, level_allocator(level))

	if sky.kind == .NONE || sky.path == "" do return false

	loaded: mb.Skybox
	err: mb.Error

	switch sky.kind {
	case .NONE: // handled above
	case .PANORAMA: loaded, err = mb.load_skybox_panorama(sky.path)
	case .CUBEMAP:  loaded, err = mb.load_skybox_cubemap(sky.path)
	}

	if err != nil {
		log.warnf("could not load the sky %q as a %v (%v); the level draws its background colour instead", sky.path, sky.kind, err)
		rt.failed = true
		return false
	}

	rt.skybox = loaded
	return true
}

/*
	Sets which image the level's sky is, and what kind of image it is, taking a
	copy of the path.

	Through here rather than by writing `settings.sky` directly, so the path is
	always the level's own to free -- an editor that assigned a path it owned
	elsewhere would leave `destroy_level` freeing memory twice, or not at all.
	The old path is kept when the new one is the same text, which is also what
	makes passing the level's own path back in safe.

	The texture is not touched: `load_level_sky` notices at the next frame.
*/
set_level_sky :: proc(level: ^Level, kind: Sky_Kind, path: string) {
	sky := &level.settings.sky
	sky.kind = kind

	if sky.path == path do return

	allocator := level_allocator(level)
	delete(sky.path, allocator)
	sky.path = strings.clone(path, allocator)
}

// Releases the loaded sky, leaving the settings alone: what `destroy_level`
// calls, and what `load_level_sky` calls before loading another.
unload_level_sky :: proc(level: ^Level) {
	rt := &level.runtime.sky
	if rt.skybox.texture != nil do mb.destroy_skybox(&rt.skybox)
	delete(rt.path, level_allocator(level))
	rt^ = {}
}

/*
	Draws the level's sky. Call it **first** inside `begin_drawing_3d`, before
	anything else in the pass.

	First, because a skybox neither tests nor writes depth (skybox.odin): it is
	a background by being drawn before everything, and anything drawn before it
	-- an editor's grid, a game's own gizmos -- is painted over instead.

	**Its own call rather than the top of `draw_level`**, for exactly that: the
	editor draws its grid between the sky and the level, and a `draw_level`
	that drew the sky would leave no room to. `draw_level_shadow_casters` is
	its own call for the same kind of reason.

	Does nothing when there is no sky, so a frame does not have to ask first.
*/
draw_level_sky :: proc(level: ^Level) {
	rt := &level.runtime.sky
	if rt.skybox.texture == nil do return

	drawn := rt.skybox
	drawn.tint = sky_tint(level.settings.sky)
	mb.draw_skybox(drawn)
}

// What a sky is drawn at: its own tint, or white when it has none. A level
// written before skies existed has a zeroed tint, and a black sky is not what
// "this file says nothing about tint" should mean.
sky_tint :: proc(sky: Sky_Settings) -> [4]f32 {
	return sky.tint if sky.tint != {} else SKY_DEFAULT_TINT
}

// Whether the level asks for a sky it could not load, so the editor can say so
// rather than leave an empty background looking like a sky that is simply
// dark.
sky_failed :: proc(level: ^Level) -> bool {
	return level.runtime.sky.failed
}
