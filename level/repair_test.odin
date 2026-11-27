package level

/*
	Repairs on load
	---------------
	A level file is hand-editable, so it can say things the editor never would:
	a parent that is not there, a loop, a repeated id, keys left out. Each test
	here writes one of those by hand and checks the level still loads, with
	the smallest repair and -- where the repair loses something -- a problem
	saying so.
*/

import "core:log"
import "core:strings"
import "core:testing"

import mb "../matchbox"

@(private)
text_bytes :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

@(test)
test_bad_parents_are_moved_to_the_root_and_reported :: proc(t: ^testing.T) {
	TEXT :: `{"version": 1, "entities": [
		{"id": 1, "name": "a", "parent": 2},
		{"id": 2, "name": "b", "parent": 1},
		{"id": 3, "name": "c", "parent": 99},
		{"id": 4, "name": "d", "parent": 4},
		{"id": 5, "name": "e", "parent": 3}
	]}`

	level, problems, err := unmarshal_level(text_bytes(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "a level with bad parents failed to load: %v", err) do return

	testing.expectf(t, len(problems) == 3, "want three problems -- the loop, the missing parent, the self-parent -- got %v", problems)

	// a is listed first in the a-b loop, so a is the one moved; b keeps a.
	want_parents := []u64{0, 1, 0, 0, 3}
	for want, i in want_parents {
		testing.expectf(t, level.entities[i].parent == want, "entities[%d] parent %d, want %d", i, level.entities[i].parent, want)
	}

	// And nothing left to hang on: every entity resolves.
	update_level(&level)
	e, _ := get_world_transform(&level, {index = 4, id = 5})
	testing.expect_value(t, e.position, [3]f32{0, 0, 0})
}

@(test)
test_missing_and_repeated_ids_get_new_ones_past_the_largest :: proc(t: ^testing.T) {
	TEXT :: `{"version": 1, "entities": [
		{"id": 0, "name": "nameless"},
		{"id": 7, "name": "first"},
		{"id": 7, "name": "second"},
		{"id": 3, "name": "child", "parent": 7}
	]}`

	level, problems, err := unmarshal_level(text_bytes(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return

	testing.expectf(t, len(problems) == 2, "want two problems, got %v", problems)

	ids := []u64{8, 7, 9, 3}
	for want, i in ids {
		testing.expectf(t, level.entities[i].id == want, "entities[%d] id %d, want %d", i, level.entities[i].id, want)
	}

	// The child's parent 7 still means the first entity that had it.
	update_level(&level)
	parent := entity_by_id(&level, level.entities[3].parent)
	if testing.expect(t, parent != nil, "the child lost its parent") {
		testing.expect_value(t, parent.name, "first")
	}
}

@(test)
test_zeros_with_no_sensible_meaning_get_defaults_silently :: proc(t: ^testing.T) {
	TEXT :: `{"version": 1, "entities": [
		{"id": 1, "name": "bare", "model": {"path": "crate.gltf"}},
		{"id": 2, "name": "lamp", "light": {"kind": "SPOT"}},
		{"id": 3, "name": "panel", "light": {"kind": "AREA_RECT"}},
		{"id": 4, "name": "bulb", "light": {"kind": "POINT"}},
		{"id": 5, "name": "stretched", "transform": {"position": [1, 2, 3], "rotation": [0, 0, 0, 2], "scale": [2, 0, 2]}},
		{"id": 6, "name": "turned", "transform": {"position": [0, 0, 0], "rotation": [0, 0.38268343, 0, 0.9238795], "scale": [1, 1, 1]}}
	]}`

	level, problems, err := unmarshal_level(text_bytes(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return
	testing.expectf(t, len(problems) == 0, "defaults were reported as problems: %v", problems)

	e := level.entities[:]

	testing.expect_value(t, e[0].transform.rotation, [4]f32{0, 0, 0, 1})
	testing.expect_value(t, e[0].transform.scale, [3]f32{1, 1, 1})
	if model, ok := e[0].model.?; testing.expect(t, ok, "the model component was lost") {
		testing.expect_value(t, model.tint, mb.WHITE)
	}

	default_spot := mb.create_spot_light({}, {})
	if lamp, ok := e[1].light.?; testing.expect(t, ok, "the lamp's light was lost") {
		testing.expect_value(t, lamp.color, mb.WHITE)
		testing.expect_value(t, lamp.intensity, 1)
		testing.expect_value(t, lamp.inner_angle, default_spot.inner_angle)
		testing.expect_value(t, lamp.outer_angle, default_spot.outer_angle)
		testing.expect_value(t, lamp.area_size, [2]f32{0, 0})
	}
	if panel, ok := e[2].light.?; testing.expect(t, ok, "the panel's light was lost") {
		testing.expect_value(t, panel.area_size, [2]f32{0.5, 0.5})
		testing.expect_value(t, panel.inner_angle, 0)
	}
	if bulb, ok := e[3].light.?; testing.expect(t, ok, "the bulb's light was lost") {
		// Unused by a point light, and left alone, so it saves as it loaded.
		testing.expect_value(t, bulb.area_size, [2]f32{0, 0})
		testing.expect_value(t, bulb.inner_angle, 0)
	}

	testing.expect_value(t, e[4].transform.position, [3]f32{1, 2, 3})
	testing.expect_value(t, e[4].transform.rotation, [4]f32{0, 0, 0, 1})
	testing.expect_value(t, e[4].transform.scale, [3]f32{2, 1, 2})

	// Unit length to the file's precision: left bit for bit.
	testing.expect_value(t, e[5].transform.rotation, [4]f32{0, 0.38268343, 0, 0.9238795})
}

@(test)
test_a_missing_model_is_kept_counted_and_tried_once :: proc(t: ^testing.T) {
	// read_entire_file logs an error for a file that is not there, and the
	// test runner counts an error log as a failure.
	context.logger = log.nil_logger()

	level := create_level()
	defer destroy_level(&level)

	append(&level.entities, Entity{id = 1, name = strings.clone("crate"), model = Model_Component{path = strings.clone("no/such/model.gltf"), tint = mb.WHITE}})
	append(&level.entities, Entity{id = 2, name = strings.clone("crate again"), model = Model_Component{path = strings.clone("no/such/model.gltf"), tint = mb.WHITE}})
	append(&level.entities, Entity{id = 3, name = strings.clone("marker")})

	for attempt in 1 ..= 2 {
		missing := load_level_models(&level)
		testing.expectf(t, missing == 2, "attempt %d: %d components missing a model, want 2", attempt, missing)
		testing.expectf(t, len(level.runtime.models) == 1, "attempt %d: %d asset table entries, want 1 per path", attempt, len(level.runtime.models))
	}

	model, _ := level.entities[0].model.?
	testing.expect(t, model.model == nil, "a model that failed to load has a pointer")
	testing.expect_value(t, model.path, "no/such/model.gltf")
}
