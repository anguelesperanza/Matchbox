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

	**Where things are:**

	- `level.odin` -- the data, its JSON, and the repairs a hand-edited file
	  can need
	- `world.odin` -- handles, and world transforms through parents
	- `draw.odin` -- lights and drawing
	- `load.odin` -- loading a level with its models, and saving one

	A game's frame, once loaded: `update_level`, `level_lights` into
	`mb.set_lights`, `draw_level_shadow_casters` before the 3D pass, and
	`draw_level` inside it. `examples/walk-level` is that, whole.

	**The file is whatever `core:encoding/json` writes for these structs**,
	with no hand-written reader or writer beside it. A component gains a field
	and the file gains a key, with nothing else to keep in step. The price is
	that the format follows Odin's marshal, so each rule relied on was read in
	Odin's source first and is asserted in a test now.
*/

import "core:encoding/json"
import "core:fmt"
import "core:math"
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

	runtime: Level_Runtime `json:"-"`,
}

/*
	What a level holds while it is in use and never writes to a file.

	One struct under one `json:"-"` rather than a tag on each field, so that a
	field added here cannot forget its tag and end up in every saved level.
*/
Level_Runtime :: struct {
	// The asset table: one load per path, however many entities share it. A
	// path that failed to load maps to nil, so it is not tried again and not
	// logged again.
	models: map[string]^mb.Model,

	// Rebuilt by `update_level` each frame: where each id is in `entities`,
	// and the scratch space resolving parents needs, kept rather than
	// allocated every frame.
	index_of:      map[u64]int,
	resolve_state: [dynamic]Resolve_State,
	resolve_chain: [dynamic]int,
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

	// A box or a sphere: a spawn point, an area that triggers something, the
	// zone a fixed camera shot is framed in. See shape.odin -- the editor draws
	// these, and a game reads `shape_bounds` or `shape_contains`.
	shape: Maybe(Shape_Component),

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

// Frees everything the level holds -- each entity's name and model path, the
// entity list, every model it loaded, and what `update_level` keeps between
// frames -- with the allocator the level was made with.
destroy_level :: proc(level: ^Level) {
	allocator := level_allocator(level)

	for &entity in level.entities {
		delete(entity.name, allocator)
		if model, ok := entity.model.?; ok do delete(model.path, allocator)
	}
	delete(level.entities)

	rt := &level.runtime
	for path, model in rt.models {
		if model != nil {
			mb.destroy_model(model)
			free(model, allocator)
		}
		delete(path, allocator)
	}
	delete(rt.models)
	delete(rt.index_of)
	delete(rt.resolve_state)
	delete(rt.resolve_chain)

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

	What gets reported:

	- **an enum name this build does not have.** json.unmarshal leaves such a
	  field at its zero value without an error (`unmarshal_string_token`, the
	  `TODO(bill)` there), so a renamed `Light_Kind` value would otherwise turn
	  a spot light into a directional one and say nothing
	- **a newer format version**, whose new fields were skipped
	- **every repair `repair_level` made** -- a missing or repeated id, a
	  parent that is not there, is the entity itself, or makes a loop

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
	repair_level(&level, &problems, allocator)

	return level, problems, nil
}

/*
	Makes a level read from a file safe to use, and says what it changed. Each
	repair is the smallest that lets the rest load: a problem costs the field
	it is in, never the file.

	- **An id of 0, or one an earlier entity already has**, gets a new id past
	  the largest in the file. A parent naming a repeated id keeps the first
	  entity that had it.
	- **A parent id that names no entity, names the entity itself, or makes a
	  loop** is cleared, so the entity sits at the root. In a loop, the entity
	  listed first is the one moved.
	- **A zero with no sensible meaning gets its default, silently**, the way
	  `set_lighting` treats a zero exposure: a key left out of a hand-written
	  file reads as zero, and a zero-length quaternion, a zero scale or a black,
	  invisible tint is never what was meant. A rotation that is not unit
	  length is normalised, but only when it is visibly off, so a value that
	  went through a save comes back bit for bit.
	- **A light component exists to light something**, so a black colour or a
	  zero intensity is a key left out -- and so are zero spot angles on a spot
	  light and a zero size on an area light. Other kinds keep their unused
	  zeros, or a point light would save differently from how it loaded.
*/
@(private)
repair_level :: proc(level: ^Level, problems: ^[dynamic]string, allocator := context.allocator) {
	// Ids first, since parents are checked against them. New ids start past
	// the largest in the file, so no repair can collide with a later entity.
	largest: u64
	for entity in level.entities do largest = max(largest, entity.id)

	seen := make(map[u64]bool, len(level.entities), allocator)
	defer delete(seen)

	for &entity, i in level.entities {
		if entity.id != 0 && !seen[entity.id] {
			seen[entity.id] = true
			continue
		}

		largest += 1
		append(problems, fmt.aprintf("entities[%d] %q: id %d is %s; given id %d",
			i, entity.name, entity.id, "missing" if entity.id == 0 else "already taken", largest,
			allocator = allocator))
		entity.id = largest
	}

	index_of := make(map[u64]int, len(level.entities), allocator)
	defer delete(index_of)
	for entity, i in level.entities do index_of[entity.id] = i

	for &entity, i in level.entities {
		if entity.parent == 0 do continue

		if entity.parent == entity.id {
			append(problems, fmt.aprintf("entities[%d] %q: is its own parent; moved to the root",
				i, entity.name, allocator = allocator))
			entity.parent = 0
		} else if _, found := index_of[entity.parent]; !found {
			append(problems, fmt.aprintf("entities[%d] %q: parent %d is not in the level; moved to the root",
				i, entity.name, entity.parent, allocator = allocator))
			entity.parent = 0
		}
	}

	// Loops, now that every parent names a real entity. Walking up from each
	// entity reaches the root or comes back round to it; the walk is bounded by
	// the entity count, so one that runs into a loop elsewhere still ends --
	// that loop is broken when its own first member is walked from.
	for &entity, i in level.entities {
		current := i
		for _ in 0 ..< len(level.entities) {
			parent_id := level.entities[current].parent
			if parent_id == 0 do break

			current = index_of[parent_id]
			if current == i {
				append(problems, fmt.aprintf("entities[%d] %q: parent %d leads back round to it; moved to the root",
					i, entity.name, entity.parent, allocator = allocator))
				entity.parent = 0
				break
			}
		}
	}

	default_spot := mb.create_spot_light({}, {})

	for &entity in level.entities {
		repair_transform(&entity.transform)

		if model, ok := &entity.model.?; ok {
			if model.tint == {} do model.tint = mb.WHITE
		}

		if light, ok := &entity.light.?; ok {
			if light.color == {} do light.color = mb.WHITE
			if light.intensity == 0 do light.intensity = 1

			if light.kind == .SPOT && light.inner_angle == 0 && light.outer_angle == 0 {
				light.inner_angle = default_spot.inner_angle
				light.outer_angle = default_spot.outer_angle
			}

			// Matchbox has no default area size; a metre square, as half-extents.
			if (light.kind == .AREA_RECT || light.kind == .AREA_DISK) && light.area_size == {} {
				light.area_size = {0.5, 0.5}
			}
		}

		// A shape with no size is a shape nobody can see or click, and a black one
		// is invisible against the viewport -- both are a key left out rather than
		// something anyone meant.
		if shape, ok := &entity.shape.?; ok {
			if shape.color == {} do shape.color = SHAPE_DEFAULTS.color

			if shape.kind == .BOX && shape.size == {} do shape.size = SHAPE_DEFAULTS.size
			if shape.kind == .SPHERE && shape.size.x == 0 do shape.size.x = SHAPE_DEFAULTS.size
		}
	}
}

@(private)
repair_transform :: proc(t: ^Level_Transform) {
	q := t.rotation
	length_squared := q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w

	if length_squared == 0 {
		t.rotation = {0, 0, 0, 1}
	} else if abs(length_squared - 1) > 1e-4 {
		t.rotation = q / math.sqrt(length_squared)
	}

	for &axis in t.scale {
		if axis == 0 do axis = 1
	}
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
