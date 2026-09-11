package level

/*
	Loading and saving
	------------------
	A level on disk is JSON (`marshal_level`, `unmarshal_level`). Loading one
	for use also loads its models and works out where everything is; saving
	one writes the file safely.
*/

import "core:encoding/json"
import "core:log"
import "core:os"
import "core:strings"

import mb ".."

// Whatever stopped a level loading or saving: a file that could not be read
// or written, or text that was not a level.
Level_Error :: union #shared_nil {
	mb.Error,
	json.Unmarshal_Error,
	json.Marshal_Error,
	os.Error,
}

/*
	Reads a `.level` file, loads every model it names and works out where
	everything is -- ready to draw.

	What was read but could not be used -- an unknown enum name, a repaired
	parent, a model file that is not there -- is **logged, not returned**: the
	level loads, with the loss written down. The editor, which wants to show
	those, calls `unmarshal_level` and `load_level_models` itself.

	The file and its models are read through `mb.read_entire_file`, so a level
	packed inside an Android apk loads the same way as one on a desktop. Model
	paths are used as written: relative to the working directory on a desktop,
	to the apk's assets on Android.

	`destroy_level` when finished; it releases the models too.
*/
load_level :: proc(path: string, allocator := context.allocator) -> (level: Level, err: Level_Error) {
	data := mb.read_entire_file(path, allocator) or_return
	defer delete(data, allocator)

	problems: [dynamic]string
	unmarshal_err: json.Unmarshal_Error
	level, problems, unmarshal_err = unmarshal_level(data, allocator)
	if unmarshal_err != nil do return {}, unmarshal_err
	defer delete_problems(problems)

	for problem in problems do log.warnf("%s: %s", path, problem)

	load_level_models(&level)
	update_level(&level)
	return level, nil
}

/*
	Loads every model the level names that is not loaded yet, once per path,
	and points each model component at its model. Returns how many components
	are left without one.

	A path that fails is logged once and remembered as failed, so it is not
	tried again on the next call; its entities are drawn as wire boxes and keep
	their path, so saving the level does not lose the reference. `load_level`
	calls this; the editor calls it again after an entity with a new path is
	added.
*/
load_level_models :: proc(level: ^Level) -> (missing: int) {
	allocator := level_allocator(level)
	rt := &level.runtime
	if rt.models == nil do rt.models = make(map[string]^mb.Model, allocator)

	for &entity in level.entities {
		component, has_model := &entity.model.?
		if !has_model do continue

		loaded, tried := rt.models[component.path]
		if !tried {
			if model, err := mb.load_model(component.path); err == nil {
				loaded = new_clone(model, allocator)
			} else {
				log.warnf("could not load model %q (%v); entities using it are drawn as wire boxes", component.path, err)
			}
			rt.models[strings.clone(component.path, allocator)] = loaded
		}

		component.model = loaded
		if loaded == nil do missing += 1
	}

	return missing
}

/*
	Writes the level to `path`, by writing a temporary file beside it and
	renaming that over the old one, so a crash or a full disk halfway through
	leaves the previous file whole rather than half a level. The rename
	replaces an existing file on Windows as well as elsewhere.

	Through `core:os` rather than Matchbox, which reads files but has no reason
	to write into a game's own folder: saving a level is for the editor, on a
	desktop. A game saving its players' progress wants `mb.get_pref_path`.
*/
save_level :: proc(level: Level, path: string, allocator := context.allocator) -> Level_Error {
	data := marshal_level(level, allocator) or_return
	defer delete(data, allocator)

	temporary := strings.concatenate({path, ".tmp"}, allocator)
	defer delete(temporary, allocator)

	os.write_entire_file(temporary, data) or_return
	os.rename(temporary, path) or_return
	return nil
}
