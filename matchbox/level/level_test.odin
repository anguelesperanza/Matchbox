package level

/*
	The level format
	----------------
	Stargate's `level_editor_plan.md` section 4 rests on claims about Odin's
	JSON: four read in its source, two not checked at all until these tests.
	Each test turns one of them into an assertion, so a later Odin that changes
	how it marshals fails a test instead of quietly changing what a level file
	means.

	**Identical bytes alone prove too little.** A save that dropped every
	component would still load and save back to the same bytes. So the round
	trip also compares what came back against what went in, field by field.

	Nothing here opens a window, touches a GPU or reads `mbi`; Matchbox is
	imported for its types. Run with `odin test matchbox/level`.
*/

import "core:encoding/json"
import "core:strings"
import "core:testing"

import mb ".."

// Every shape the format has: a model, a light with enums that are not the
// zero value, a marker with neither component, a parent, and floats with no
// short decimal form (1/3, and a 45-degree turn's quaternion).
@(private)
make_sample_level :: proc() -> Level {
	level := create_level()

	level.settings.background = {0.05, 0.06, 0.09, 1}
	level.settings.lighting.tonemap = .ACES
	level.settings.lighting.shadows = mb.SHADOW_DEFAULTS
	level.settings.lighting.shadows.technique = .CASCADED
	level.settings.lighting.ambient = {
		kind         = .HEMISPHERE,
		color        = {0.4, 0.45, 0.6, 1},
		ground_color = {0.2, 0.18, 0.15, 1},
	}

	append(&level.entities, Entity{
		id        = 1,
		name      = strings.clone("stove"),
		transform = {position = {-4, 0, -3}, rotation = {0, 0.38268343, 0, 0.9238795}, scale = {3, 3, 3}},
		model     = Model_Component{path = strings.clone("assets/models/stove.gltf"), tint = {1, 1, 1, 1}, casts_shadow = true},
	})
	append(&level.entities, Entity{
		id        = 2,
		name      = strings.clone("torch"),
		transform = {position = {0.1, 1.0 / 3.0, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		light     = Light_Component{
			kind         = .SPOT,
			color        = {1, 0.2, 0, 1},
			intensity    = 2.5,
			casts_shadow = true,
			inner_angle  = 14,
			outer_angle  = 26,
		},
	})
	append(&level.entities, Entity{
		id        = 3,
		name      = strings.clone("player_spawn"),
		transform = {position = {0, 0, 5}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
	})
	append(&level.entities, Entity{
		id        = 4,
		name      = strings.clone("pot"),
		parent    = 1,
		transform = {position = {0, 0.3, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		model     = Model_Component{path = strings.clone("assets/models/pot.gltf"), tint = {0.9, 0.9, 0.9, 1}},
	})

	return level
}

@(private)
expect_same_level :: proc(t: ^testing.T, want, got: Level) {
	testing.expect_value(t, got.version, want.version)
	testing.expectf(t, got.settings == want.settings, "settings differ:\n want %v\n got  %v", want.settings, got.settings)

	if !testing.expect_value(t, len(got.entities), len(want.entities)) do return

	for w, i in want.entities {
		g := got.entities[i]

		testing.expect_value(t, g.id, w.id)
		testing.expect_value(t, g.name, w.name)
		testing.expect_value(t, g.parent, w.parent)
		testing.expectf(t, g.transform == w.transform, "entity %d transform:\n want %v\n got  %v", i, w.transform, g.transform)

		wm, w_has_model := w.model.?
		gm, g_has_model := g.model.?
		testing.expectf(t, g_has_model == w_has_model, "entity %d: has model %v, want %v", i, g_has_model, w_has_model)
		if w_has_model && g_has_model {
			testing.expect_value(t, gm.path, wm.path)
			testing.expect_value(t, gm.tint, wm.tint)
			testing.expect_value(t, gm.casts_shadow, wm.casts_shadow)
		}

		wl, w_has_light := w.light.?
		gl, g_has_light := g.light.?
		testing.expectf(t, g_has_light == w_has_light, "entity %d: has light %v, want %v", i, g_has_light, w_has_light)
		if w_has_light && g_has_light {
			testing.expectf(t, gl == wl, "entity %d light:\n want %v\n got  %v", i, wl, gl)
		}
	}
}

// The parsed tree of a marshalled level, for tests asserting on the text's
// shape rather than on what it loads back as.
@(private)
parse_marshalled :: proc(t: ^testing.T, level: Level) -> (root: json.Object, value: json.Value, ok: bool) {
	data, err := marshal_level(level)
	defer delete(data)
	if !testing.expectf(t, err == nil, "marshal: %v", err) do return

	parse_err: json.Error
	value, parse_err = json.parse(data)
	if !testing.expectf(t, parse_err == nil, "parse: %v", parse_err) do return

	root, ok = value.(json.Object)
	return
}

// `json.Value` is a union holding maps and arrays, so it has no `==`.
@(private)
expect_json_string :: proc(t: ^testing.T, value: json.Value, want: string, what: string) {
	got, is_string := value.(json.String)
	testing.expectf(t, is_string && got == want, "%s written as %v, want the name %q", what, value, want)
}

@(test)
test_round_trip_gives_identical_bytes_and_identical_data :: proc(t: ^testing.T) {
	original := make_sample_level()
	defer destroy_level(&original)

	first, marshal_err := marshal_level(original)
	defer delete(first)
	if !testing.expectf(t, marshal_err == nil, "first marshal: %v", marshal_err) do return

	loaded, problems, err := unmarshal_level(first)
	defer destroy_level(&loaded)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return
	testing.expectf(t, len(problems) == 0, "a clean file reported problems: %v", problems)

	second, second_err := marshal_level(loaded)
	defer delete(second)
	if !testing.expectf(t, second_err == nil, "second marshal: %v", second_err) do return

	testing.expectf(t, string(first) == string(second),
		"saving what was loaded changed the bytes\n--- first\n%s\n--- second\n%s", first, second)

	expect_same_level(t, original, loaded)
}

@(test)
test_components_are_objects_or_null_and_runtime_fields_are_not_written :: proc(t: ^testing.T) {
	level := make_sample_level()
	defer destroy_level(&level)

	root, value, ok := parse_marshalled(t, level)
	defer json.destroy_value(value)
	if !testing.expect(t, ok, "the file is not a JSON object") do return

	entities := root["entities"].(json.Array)
	if !testing.expect_value(t, len(entities), 4) do return

	// A present component is written as the component itself, not wrapped in
	// anything saying which variant of the Maybe it is.
	stove := entities[0].(json.Object)
	stove_model, is_object := stove["model"].(json.Object)
	testing.expect(t, is_object, "a present model component is not written as an object")

	// An absent one is written, as null -- not left out.
	spawn := entities[2].(json.Object)
	light, has_light_key := spawn["light"]
	testing.expect(t, has_light_key, "an absent light is left out rather than written as null")
	_, is_null := light.(json.Null)
	testing.expectf(t, is_null, "an absent light is written as %v, not null", light)

	// `json:"-"` keeps both runtime fields out of the file.
	_, has_world := stove["world"]
	testing.expect(t, !has_world, "the world matrix was written")

	if is_object {
		_, has_pointer := stove_model["model"]
		testing.expect(t, !has_pointer, "the loaded-model pointer was written")
	}
}

@(test)
test_enums_are_written_by_name :: proc(t: ^testing.T) {
	level := make_sample_level()
	defer destroy_level(&level)

	root, value, ok := parse_marshalled(t, level)
	defer json.destroy_value(value)
	if !testing.expect(t, ok, "the file is not a JSON object") do return

	torch := root["entities"].(json.Array)[1].(json.Object)
	expect_json_string(t, torch["light"].(json.Object)["kind"], "SPOT", "light kind")

	lighting := root["settings"].(json.Object)["lighting"].(json.Object)
	expect_json_string(t, lighting["tonemap"], "ACES", "tonemap")
	expect_json_string(t, lighting["shadows"].(json.Object)["technique"], "CASCADED", "shadow technique")
}

@(test)
test_runtime_fields_are_never_read_from_a_file :: proc(t: ^testing.T) {
	// Keys that share a name with a `json:"-"` field, holding values that would
	// be nonsense if they were read into it.
	TEXT :: `{
		"version": 1,
		"entities": [
			{
				"id": 7, "name": "crate", "parent": 0,
				"world": [1, 2, 3],
				"transform": {"position": [1, 2, 3], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
				"model": {"path": "crate.glb", "tint": [1, 1, 1, 1], "casts_shadow": false, "model": 12345},
				"light": null
			}
		]
	}`

	level, problems, err := unmarshal_level(transmute([]byte)string(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return
	if !testing.expect_value(t, len(level.entities), 1) do return

	crate := level.entities[0]
	testing.expect(t, crate.world == {}, "the world matrix was filled from the file")

	model, has_model := crate.model.?
	if testing.expect(t, has_model, "the model component was lost") {
		testing.expect(t, model.model == nil, "the loaded-model pointer was filled from the file")
		testing.expect_value(t, model.path, "crate.glb")
	}

	_, has_light := crate.light.?
	testing.expect(t, !has_light, "a null light was read as present")
}

@(test)
test_unknown_keys_are_skipped :: proc(t: ^testing.T) {
	// As a newer editor might write it: a settings block, an entity field and
	// a component field this build has never heard of.
	TEXT :: `{
		"version": 1,
		"colour_grade_v9": {"strength": 0.5, "curve": [1, 2, 3]},
		"entities": [
			{
				"id": 2, "name": "lamp", "parent": 0,
				"mass": 12,
				"transform": {"position": [0, 1, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
				"light": {"kind": "POINT", "color": [1, 1, 1, 1], "intensity": 3, "flicker": true}
			}
		]
	}`

	level, problems, err := unmarshal_level(transmute([]byte)string(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return
	testing.expectf(t, len(problems) == 0, "unknown keys reported as problems: %v", problems)
	if !testing.expect_value(t, len(level.entities), 1) do return

	lamp := level.entities[0]
	testing.expect_value(t, lamp.name, "lamp")
	testing.expect_value(t, lamp.transform.position, [3]f32{0, 1, 0})

	light, has_light := lamp.light.?
	if testing.expect(t, has_light, "the light was lost") {
		testing.expect_value(t, light.kind, mb.Light_Kind.POINT)
		testing.expect_value(t, light.intensity, 3)
	}
}

@(test)
test_an_unknown_enum_name_is_reported_and_read_as_zero :: proc(t: ^testing.T) {
	TEXT :: `{
		"version": 1,
		"entities": [
			{
				"id": 5, "name": "beam", "parent": 0,
				"transform": {"position": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1]},
				"light": {"kind": "LASER", "color": [1, 0, 0, 1], "intensity": 4}
			}
		]
	}`

	level, problems, err := unmarshal_level(transmute([]byte)string(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "an unknown name failed the whole load: %v", err) do return

	if testing.expectf(t, len(problems) == 1, "want one problem, got %v", problems) {
		testing.expectf(t, strings.contains(problems[0], "level.entities[0].light.kind"),
			"the problem does not say where: %q", problems[0])
		testing.expectf(t, strings.contains(problems[0], "LASER"),
			"the problem does not say what: %q", problems[0])
	}

	// What json.unmarshal does with the name, asserted so that a change to it
	// is noticed: the zero value, silently -- which is why the check exists.
	if !testing.expect_value(t, len(level.entities), 1) do return
	light, has_light := level.entities[0].light.?
	if testing.expect(t, has_light, "the light was lost") {
		testing.expect_value(t, light.kind, mb.Light_Kind.DIRECTIONAL)
		testing.expect_value(t, light.intensity, 4)
	}
}

@(test)
test_a_newer_format_version_is_reported :: proc(t: ^testing.T) {
	TEXT :: `{"version": 99, "entities": []}`

	level, problems, err := unmarshal_level(transmute([]byte)string(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return

	if testing.expectf(t, len(problems) == 1, "want one problem, got %v", problems) {
		testing.expectf(t, strings.contains(problems[0], "version 99"), "the problem does not name the version: %q", problems[0])
	}
}
