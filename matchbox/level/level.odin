package level

/*
	Levels
	------
	A level saved by the Stargate editor, loaded by the editor or by any
	Matchbox game -- `import "matchbox/level"` beside `import "matchbox"`.
	Stargate's `level_editor_plan.md`, sections 3, 4 and 5.11, is the design
	and the alternatives it turned down.

	**A package of its own inside the Matchbox folder**, rather than files in
	package `matchbox` or a repository outside it:

	- inside the folder, because Stargate is young and one place to change the
	  renderer and the format it draws is the easiest thing to work in, and
	  because a level is a description of what to render. It may move out once
	  Stargate becomes a proper editor, or stay; that is decided then.
	- its own package, so the format's churn while the editor is young stays
	  out of `matchbox`'s own namespace, and moving it later is a folder move
	  and an import line rather than an untangling.
	- and it imports Matchbox as `..`, its own parent folder, so it always
	  reaches the same copy of Matchbox as the program importing both. A
	  package kept anywhere else reaches Matchbox by a path of its own, and two
	  paths to Matchbox are two packages: two `mbi` globals, and an `mb.Model`
	  from one is not an `mb.Model` to the other.

	**So far this is the data and its JSON, nothing more.** Loading models,
	resolving parents, drawing and lights come next. `level_test.odin` holds
	what is here to the claims the plan makes about it.

	**The file is whatever `core:encoding/json` writes for these structs**,
	with no hand-written reader or writer beside it. A component gains a field
	and the file gains a key, with nothing else to keep in step. The price is
	that the format follows Odin's marshal, so each rule relied on was read in
	Odin's source first and is asserted in a test now.
*/

import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strings"

import mb ".."

/*
	What this build of the package reads and writes.

	A named constant of struct type rather than a loose `LEVEL_VERSION`, per
	CLAUDE.md -- `BUTTON_STYLE` is the precedent it names.
*/
Level_Format :: struct {
	version:   int,
	extension: string,
}

LEVEL_FORMAT :: Level_Format{version = 1, extension = ".level"}

Level :: struct {
	version:  int,
	settings: Level_Settings,
	entities: [dynamic]Entity,
}

Level_Settings :: struct {
	background: [4]f32,

	// Saved whole rather than as a level-owned copy of some of its fields, so
	// that every lighting feature Matchbox gains is in the file and the
	// editor without being ported by hand. The plan's section 4 has the trade.
	lighting: mb.Lighting_Settings,
}

Entity :: struct {
	id:        u64,             // stable across saves; never an array index; 0 means none
	name:      string,
	parent:    u64,             // the parent's id, or 0 -- plan 5.11
	transform: Level_Transform, // relative to the parent

	// A `Maybe` rather than a `bit_set` of which components are present plus a
	// field each: json.marshal writes a bit_set as one bare integer, which
	// tells a person reading the file nothing.
	model: Maybe(Model_Component),
	light: Maybe(Light_Component),

	// Resolved once a frame and never saved -- nor could it be, since
	// json.marshal rejects every matrix type outright.
	world: matrix[4, 4]f32 `json:"-"`,
}

/*
	Where an entity is, relative to its parent.

	Not `mb.Transform`, which holds a `quaternion128`: json.marshal rejects
	every quaternion (marshal.odin, `Type_Info_Quaternion`). The rotation is the
	same quaternion as four plain numbers, x y z w with the real part last, and
	becomes a quaternion again when it is drawn.
*/
Level_Transform :: struct {
	position: [3]f32,
	rotation: [4]f32,
	scale:    [3]f32,
}

Model_Component :: struct {
	path:         string, // relative to the project root, with forward slashes
	tint:         [4]f32,
	casts_shadow: bool,

	// The loaded model, from the level's asset table. A GPU handle means
	// nothing in a file, so it is never written and never read.
	model: ^mb.Model `json:"-"`,
}

/*
	A light, minus where it is and which way it points: both come from the
	entity's world transform, so the rotate gizmo aims a light and there is no
	second direction to keep in step with the first. Plan section 4.
*/
Light_Component :: struct {
	kind:         mb.Light_Kind,
	color:        [4]f32,
	intensity:    f32, // multiplied into color when the mb.Light is built
	casts_shadow: bool,
	inner_angle:  f32, // spot, degrees
	outer_angle:  f32, // spot, degrees
	area_size:    [2]f32, // area rect half-extents; x alone is a disk's radius
}

/*
	An empty level at the current format version, lit with Matchbox's own
	defaults. What New starts from.

	Names and paths put into it later are freed by `destroy_level` with the
	allocator given here, so allocate them with the same one.
*/
create_level :: proc(allocator := context.allocator) -> Level {
	return Level{
		version  = LEVEL_FORMAT.version,
		settings = {background = {0, 0, 0, 1}, lighting = mb.LIGHTING_DEFAULTS},
		entities = make([dynamic]Entity, allocator),
	}
}

// Frees the entity list and every entity's name and model path, with the
// allocator the entity list was made with.
destroy_level :: proc(level: ^Level) {
	allocator := level.entities.allocator

	for &entity in level.entities {
		delete(entity.name, allocator)
		if model, ok := entity.model.?; ok do delete(model.path, allocator)
	}

	delete(level.entities)
	level^ = {}
}

/*
	The level as the text of a `.level` file.

	**Enum names rather than numbers** (`use_enum_names`), for a file a person
	can read that also survives an enum being reordered. **Pretty-printed**, so
	a moved entity is a small diff rather than one changed line a megabyte
	long.
*/
marshal_level :: proc(level: Level, allocator := context.allocator) -> (data: []byte, err: json.Marshal_Error) {
	return json.marshal(level, {pretty = true, use_enum_names = true}, allocator)
}

/*
	A level from the text of a `.level` file.

	`problems` is what was read but could not be used, one line each, for the
	caller to log or show; free it with `delete_problems`. The level comes back
	regardless -- a lost field is a loss rather than a failure, the same rule
	unknown keys follow.

	Two kinds of problem today:

	- **an enum name this build does not have.** json.unmarshal leaves such a
	  field at its zero value without an error (`unmarshal_string_token`, the
	  `TODO(bill)` there), so a renamed `Light_Kind` value would otherwise turn
	  a spot light into a directional one and say nothing
	- **a newer format version**, whose new fields were skipped

	On an error nothing is returned and nothing is left allocated.
*/
unmarshal_level :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	level: Level,
	problems: [dynamic]string,
	err: json.Unmarshal_Error,
) {
	if err = json.unmarshal(data, &level, allocator = allocator); err != nil {
		destroy_level(&level)
		return {}, nil, err
	}

	// The second read, as a plain tree, is the only way to see what the typed
	// read threw away: by the time unmarshal returns, a name it did not know
	// and a name that really meant the zero value look identical.
	value, parse_err := json.parse(data, allocator = allocator)
	defer json.destroy_value(value, allocator)

	if parse_err != nil {
		// Unreachable while unmarshal and parse agree on what JSON is, which
		// they do today; kept so that a disagreement is an error, not a crash.
		destroy_level(&level)
		return {}, nil, parse_err
	}

	problems = make([dynamic]string, allocator)

	if level.version > LEVEL_FORMAT.version {
		append(&problems, fmt.aprintf(
			"saved as format version %d, and this build reads version %d: anything newer was skipped",
			level.version, LEVEL_FORMAT.version, allocator = allocator))
	}

	check_enum_names(value, type_info_of(Level), "level", &problems, allocator)

	return level, problems, nil
}

// Frees what `unmarshal_level` returned as `problems`.
delete_problems :: proc(problems: [dynamic]string) {
	for problem in problems do delete(problem, problems.allocator)
	delete(problems)
}

/*
	Walks the parsed file alongside the type it was read into, and reports
	every enum field whose text is not one of that enum's names.

	Generic over the type rather than written out per component, so a
	component added later is checked without anything being added here -- the
	same reason the format itself is not hand-written.
*/
@(private)
check_enum_names :: proc(
	value: json.Value,
	type: ^reflect.Type_Info,
	path: string,
	problems: ^[dynamic]string,
	allocator := context.allocator,
) {
	base := reflect.type_info_base(type)

	#partial switch info in base.variant {
	case reflect.Type_Info_Enum:
		name, is_name := value.(json.String)
		if !is_name {
			append(problems, fmt.aprintf("%s: expected one of %v's names, found %v",
				path, type.id, value, allocator = allocator))
			return
		}

		for known in info.names {
			if known == name do return
		}

		append(problems, fmt.aprintf("%s: %q is not a %v, and was read as its zero value",
			path, name, type.id, allocator = allocator))

	case reflect.Type_Info_Struct:
		object, is_object := value.(json.Object)
		if !is_object do return

		for field in reflect.struct_fields_zipped(base.id) {
			key := json_key(field)
			if key == "-" do continue

			if child, found := object[key]; found {
				check_enum_names(child, field.type, fmt.tprintf("%s.%s", path, key), problems, allocator)
			}
		}

	case reflect.Type_Info_Union:
		// A `Maybe`: null is "not there", anything else is its one variant.
		if len(info.variants) != 1 do return

		#partial switch _ in value {
		case nil, json.Null:
		case:
			check_enum_names(value, info.variants[0], path, problems, allocator)
		}

	case reflect.Type_Info_Array:
		check_enum_elements(value, info.elem, path, problems, allocator)
	case reflect.Type_Info_Dynamic_Array:
		check_enum_elements(value, info.elem, path, problems, allocator)
	case reflect.Type_Info_Slice:
		check_enum_elements(value, info.elem, path, problems, allocator)
	}
}

@(private)
check_enum_elements :: proc(
	value: json.Value,
	elem: ^reflect.Type_Info,
	path: string,
	problems: ^[dynamic]string,
	allocator := context.allocator,
) {
	array, is_array := value.(json.Array)
	if !is_array do return

	for child, i in array {
		check_enum_names(child, elem, fmt.tprintf("%s[%d]", path, i), problems, allocator)
	}
}

// The key json.marshal writes a field under: the name in its `json` tag, or
// the field's own name when the tag has none. Mirrors marshal.odin and
// unmarshal.odin, which both cut the tag at the first comma.
@(private)
json_key :: proc(field: reflect.Struct_Field) -> string {
	tag := reflect.struct_tag_get(field.tag, "json")
	if comma := strings.index_byte(tag, ','); comma >= 0 do tag = tag[:comma]
	return tag if tag != "" else field.name
}
