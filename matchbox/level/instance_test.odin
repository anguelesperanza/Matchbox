package level

/*
	Instances and primitives, measured
	-----------------------------------
	Instancing is only worth having if a level written with it is the same
	level. So the tests here are mostly round trips: a level packed, read back
	and compared field by field against what went in, and packed again to see
	that the bytes settle.

	`expect_same_level` (level_test.odin) is what compares them, so a component
	that came back with the wrong tint or the wrong path fails here rather than
	looking like a smaller file.

	Nothing here opens a window or touches a GPU: `create_primitive_model` is
	the only thing in these two files that needs one, and it is not called.
*/

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Six crates, three of them identical, one tinted red, one marked unique, and
// a barrel -- every case packing has to tell apart, in one level.
@(private)
make_instanced_level :: proc() -> Level {
	level := create_level()

	crate :: proc(id: u64, x: f32, tint: [4]f32 = {1, 1, 1, 1}, unique := false) -> Entity {
		return Entity{
			id        = id,
			name      = strings.clone("crate"),
			transform = {position = {x, 0, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
			model     = Model_Component{
				path         = strings.clone("assets/models/crate.gltf"),
				tint         = tint,
				casts_shadow = true,
				unique       = unique,
			},
		}
	}

	append(&level.entities, crate(1, 0))
	append(&level.entities, crate(2, 2))
	append(&level.entities, crate(3, 4))
	append(&level.entities, crate(4, 6, tint = {1, 0.2, 0.2, 1}))       // looks different
	append(&level.entities, crate(5, 8, unique = true))                 // asked to stay its own
	append(&level.entities, Entity{
		id        = 6,
		name      = strings.clone("barrel"),
		transform = {position = {10, 0, 0}, rotation = {0, 0, 0, 1}, scale = {1, 1, 1}},
		model     = Model_Component{path = strings.clone("assets/models/barrel.gltf"), tint = {1, 1, 1, 1}},
	})

	return level
}

@(test)
test_instancing_round_trips_to_the_same_level :: proc(t: ^testing.T) {
	original := make_instanced_level()
	defer destroy_level(&original)

	first, marshal_err := marshal_level(original, instancing = true)
	defer delete(first)
	if !testing.expectf(t, marshal_err == nil, "marshal: %v", marshal_err) do return

	loaded, problems, err := unmarshal_level(first)
	defer destroy_level(&loaded)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return
	testing.expectf(t, len(problems) == 0, "a clean instanced file reported problems: %v", problems)

	// Every model component is whole again: the three folded crates know their
	// path, their tint and that they cast a shadow.
	expect_same_level(t, original, loaded)

	second, second_err := marshal_level(loaded, instancing = true)
	defer delete(second)
	if !testing.expectf(t, second_err == nil, "second marshal: %v", second_err) do return

	testing.expectf(t, string(first) == string(second),
		"saving what was loaded changed the bytes\n--- first\n%s\n--- second\n%s", first, second)
}

/*
	The same level written without instancing loads to the same thing. The two
	files differ; the two levels must not.
*/
@(test)
test_instancing_off_gives_the_same_level_as_instancing_on :: proc(t: ^testing.T) {
	original := make_instanced_level()
	defer destroy_level(&original)

	long, long_err := marshal_level(original, instancing = false)
	defer delete(long)
	if !testing.expectf(t, long_err == nil, "marshal: %v", long_err) do return

	short, short_err := marshal_level(original, instancing = true)
	defer delete(short)
	if !testing.expectf(t, short_err == nil, "marshal: %v", short_err) do return

	testing.expectf(t, len(short) < len(long),
		"instancing made the file no smaller: %d bytes against %d", len(short), len(long))

	from_long, long_problems, e1 := unmarshal_level(long)
	defer destroy_level(&from_long)
	defer delete_problems(long_problems)
	if !testing.expectf(t, e1 == nil, "unmarshal long: %v", e1) do return

	from_short, short_problems, e2 := unmarshal_level(short)
	defer destroy_level(&from_short)
	defer delete_problems(short_problems)
	if !testing.expectf(t, e2 == nil, "unmarshal short: %v", e2) do return

	expect_same_level(t, original, from_long)
	expect_same_level(t, original, from_short)
}

/*
	What actually goes in the file: one instance for the three crates that
	match, nothing for the red one, the unique one or the barrel, and the three
	entities carrying a reference rather than a path.
*/
@(test)
test_only_repeated_components_are_folded :: proc(t: ^testing.T) {
	level := make_instanced_level()
	defer destroy_level(&level)

	data, err := marshal_level(level, instancing = true)
	defer delete(data)
	if !testing.expectf(t, err == nil, "marshal: %v", err) do return

	value, parse_err := json.parse(data)
	defer json.destroy_value(value)
	if !testing.expectf(t, parse_err == nil, "parse: %v", parse_err) do return

	root := value.(json.Object)

	instances, has_instances := root["instances"].(json.Array)
	if !testing.expect(t, has_instances, "no instances array in the file") do return
	one := testing.expectf(t, len(instances) == 1,
		"want one instance -- the three identical crates -- got %d", len(instances))
	if !one do return

	source := instances[0].(json.Object)
	testing.expect_value(t, source["id"].(json.Float), 1)
	expect_json_string(t, source["model"].(json.Object)["path"], "assets/models/crate.gltf", "the instance's path")

	entities := root["entities"].(json.Array)
	if !testing.expect_value(t, len(entities), 6) do return

	// The three folded crates: a reference, and no model component at all. The
	// component is what has to go -- an emptied one costs every key it has.
	for i in 0 ..< 3 {
		entity := entities[i].(json.Object)
		testing.expectf(t, entity["instance"].(json.Float) == 1, "entities[%d] is not in instance 1", i)

		_, still_has_one := entity["model"].(json.Object)
		testing.expectf(t, !still_has_one,
			"entities[%d] kept a model component beside its instance, which is what makes the file no smaller", i)
	}

	// The red one, the unique one and the barrel keep everything.
	for i in 3 ..< 6 {
		entity := entities[i].(json.Object)
		testing.expectf(t, entity["instance"].(json.Float) == 0,
			"entities[%d] was folded into an instance and should not have been", i)

		model, has_model := entity["model"].(json.Object)
		if !testing.expectf(t, has_model, "entities[%d] lost its model", i) do continue
		path, is_string := model["path"].(json.String)
		testing.expectf(t, is_string && path != "", "entities[%d] lost its path", i)
	}
}

/*
	An entity naming an instance that is not in the file loses its model and
	says so, rather than drawing whatever instance happens to share the id --
	the same rule a parent id naming nothing follows.
*/
@(test)
test_an_instance_that_is_not_there_is_reported :: proc(t: ^testing.T) {
	TEXT :: `{
		"version": 1,
		"instances": [
			{ "id": 1, "model": { "path": "assets/crate.gltf", "tint": [1,1,1,1], "casts_shadow": true } }
		],
		"entities": [
			{ "id": 1, "name": "crate", "transform": { "position": [0,0,0], "rotation": [0,0,0,1], "scale": [1,1,1] },
			  "instance": 1 },
			{ "id": 2, "name": "ghost", "transform": { "position": [1,0,0], "rotation": [0,0,0,1], "scale": [1,1,1] },
			  "instance": 9 }
		]
	}`

	level, problems, err := unmarshal_level(transmute([]byte)string(TEXT))
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return

	crate, has_crate := level.entities[0].model.?
	testing.expect(t, has_crate, "the entity naming instance 1 lost its model")
	testing.expect_value(t, crate.path, "assets/crate.gltf")
	testing.expect(t, crate.casts_shadow, "the instance's casts_shadow did not reach the entity")

	_, has_ghost := level.entities[1].model.?
	testing.expect(t, !has_ghost, "the entity naming a missing instance kept a model")

	found := false
	for problem in problems {
		if strings.contains(problem, "instance 9") do found = true
	}
	testing.expectf(t, found, "a missing instance was not reported: %v", problems)
}

/*
	Two entities sharing an instance must not share a string: `destroy_level`
	frees a path per entity, so one allocation reached twice is a double free.
	Checked by writing over one and reading the other.
*/
@(test)
test_expanded_instances_do_not_share_their_path_allocation :: proc(t: ^testing.T) {
	original := make_instanced_level()
	defer destroy_level(&original)

	data, _ := marshal_level(original, instancing = true)
	defer delete(data)

	level, problems, err := unmarshal_level(data)
	defer destroy_level(&level)
	defer delete_problems(problems)
	if !testing.expectf(t, err == nil, "unmarshal: %v", err) do return

	first  := level.entities[0].model.?.path
	second := level.entities[1].model.?.path

	testing.expect_value(t, first, second)
	testing.expectf(t, raw_data(first) != raw_data(second),
		"two entities in one instance point at the same bytes; destroy_level would free them twice")
}

// ---- primitives -------------------------------------------------------------------

@(test)
test_a_primitive_path_names_its_kind_and_back :: proc(t: ^testing.T) {
	for kind in Primitive_Kind {
		if kind == .NONE do continue

		path := primitive_path(kind, context.temp_allocator)
		testing.expectf(t, is_primitive_path(path), "%v became %q, which is not a primitive path", kind, path)
		testing.expect_value(t, primitive_from_path(path), kind)
	}

	// A file is not a primitive, and a prefixed name this build does not know
	// is a model that will not load rather than the wrong shape.
	testing.expect_value(t, primitive_from_path("assets/models/crate.gltf"), Primitive_Kind.NONE)
	testing.expect_value(t, primitive_from_path("primitive:capsule"), Primitive_Kind.NONE)
	testing.expect(t, is_primitive_path("primitive:capsule"),
		"an unknown primitive name must still read as a primitive path, or the loader tries to open it as a file")
	testing.expect(t, !is_primitive_path("assets/primitive:cube.gltf"),
		"the prefix is only a prefix at the start of a path")
}

/*
	A primitive survives the file the same way a path does, and instancing folds
	two of the same primitive together -- which is the case a level blocked out
	of cubes is made of.
*/
@(test)
test_primitives_round_trip_and_instance :: proc(t: ^testing.T) {
	original := create_level()
	defer destroy_level(&original)

	for i in 0 ..< 3 {
		append(&original.entities, Entity{
			id        = u64(i + 1),
			name      = strings.clone("block"),
			transform = {position = {f32(i) * 2, 0, 0}, rotation = {0, 0, 0, 1}, scale = {2, 1, 4}},
			model     = Model_Component{
				path         = strings.clone(primitive_path(.CUBE, context.temp_allocator)),
				tint         = {1, 1, 1, 1},
				casts_shadow = true,
			},
		})
	}

	data, err := marshal_level(original, instancing = true)
	defer delete(data)
	if !testing.expectf(t, err == nil, "marshal: %v", err) do return

	loaded, problems, unmarshal_err := unmarshal_level(data)
	defer destroy_level(&loaded)
	defer delete_problems(problems)
	if !testing.expectf(t, unmarshal_err == nil, "unmarshal: %v", unmarshal_err) do return
	testing.expectf(t, len(problems) == 0, "a level of cubes reported problems: %v", problems)

	expect_same_level(t, original, loaded)

	for entity, i in loaded.entities {
		model, ok := entity.model.?
		if !testing.expectf(t, ok, "entities[%d] lost its model", i) do continue
		testing.expect_value(t, primitive_from_path(model.path), Primitive_Kind.CUBE)
	}
}
