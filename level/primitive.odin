package level

/*
	Primitives
	----------
	A cube, a sphere, a cylinder or a plane placed in a level with no file
	behind it, so a level can be blocked out before any of its art exists.
	Stargate's `level_editor_plan.md` section 5.16 is the design.

	**A primitive is a model whose source is generated, not a component of its
	own.** It rides in `Model_Component.path` under a reserved prefix --
	`primitive:cube` -- and `load_level_models` builds the mesh instead of
	reading a file. Everything that already reads a model component therefore
	works on a primitive with nothing added: picking against its bounds, the
	selection outline, `draw_level`, `draw_level_shadow_casters`, duplicating,
	undo, the asset table's one-model-per-path sharing, and instancing.

	*Alternative:* a fourth component beside `model`, `light` and `shape`, which
	reads better in the file. Rejected because every site that asks
	`entity.model.?` -- eight of them in the editor alone, plus `draw.odin` and
	`world.odin` here -- would need a second branch that does the same thing,
	and a primitive really is a model: it has parts, bounds and a material, and
	the only thing that differs is where the vertices came from.

	**A primitive carries no size.** A cube is one unit and a sphere half a unit
	across, and the entity's own scale is what makes it bigger -- otherwise a
	size in the component and a scale in the transform would be two numbers
	meaning one thing, which is the state CLAUDE.md says belongs in one place.
*/

import "core:strings"

import mb "../matchbox"

/*
	What `primitive:` can name. `NONE` is not a primitive at all -- a path with
	no prefix, which is a file.

	Adding a kind here is a file that older builds cannot draw: they read the
	path, fail to make a mesh for it, and fall back to the wire box a missing
	model already gets. A loss rather than a failure, the rule section 4 of the
	plan sets for the whole format.
*/
Primitive_Kind :: enum {
	NONE,
	CUBE,
	SPHERE,
	CYLINDER,
	PLANE,
}

Primitive_Format :: struct {
	prefix: string,
}

// Not `/` or `\`, so a primitive path can never collide with a real file under
// `assets/`, and not a bare word, so `cube.gltf` in the project root still
// loads as itself.
PRIMITIVE_FORMAT :: Primitive_Format{prefix = "primitive:"}

// What each kind is written as after the prefix. Lower case, so the whole path
// reads like the path it stands in for.
PRIMITIVE_NAMES :: [Primitive_Kind]string{
	.NONE     = "",
	.CUBE     = "cube",
	.SPHERE   = "sphere",
	.CYLINDER = "cylinder",
	.PLANE    = "plane",
}

// The path a level stores a primitive of `kind` under. A temporary string: it
// is cloned with the level's allocator wherever one is kept.
primitive_path :: proc(kind: Primitive_Kind, allocator := context.temp_allocator) -> string {
	if kind == .NONE do return ""
	names := PRIMITIVE_NAMES
	return strings.concatenate({PRIMITIVE_FORMAT.prefix, names[kind]}, allocator)
}

/*
	Which primitive a model path names, or `NONE` when it names a file.

	A path under the prefix whose name this build does not know also comes back
	`NONE`, and is then a model that will not load -- the wire box, and a log
	line. That is deliberate: a newer editor's `primitive:capsule` should look
	like a missing model here, not like a cube.
*/
primitive_from_path :: proc(path: string) -> Primitive_Kind {
	if !strings.has_prefix(path, PRIMITIVE_FORMAT.prefix) do return .NONE

	name  := path[len(PRIMITIVE_FORMAT.prefix):]
	names := PRIMITIVE_NAMES

	for kind in Primitive_Kind {
		if kind != .NONE && names[kind] == name do return kind
	}
	return .NONE
}

// Whether a model path is a primitive at all, known to this build or not --
// what `load_level_models` asks before it tries to read a file that is not
// there.
is_primitive_path :: proc(path: string) -> bool {
	return strings.has_prefix(path, PRIMITIVE_FORMAT.prefix)
}

/*
	The mesh for a primitive kind, at the size the level assumes: a cube and a
	plane one unit across, a sphere half a unit in radius so it fills the same
	box, and a cylinder half a unit in radius and one unit tall so it does too.

	**Every kind fits the same unit box on purpose.** An entity switched from a
	cube to a sphere in the inspector keeps the size it looked, and a path tool
	spacing copies by their bounds gets the same spacing whichever it used.

	Needs a GPU, like `mb.load_model`.
*/
create_primitive_model :: proc(kind: Primitive_Kind) -> (model: mb.Model, err: mb.Error) {
	switch kind {
	case .NONE:     return {}, .No_Geometry
	case .CUBE:     return mb.create_cube_model(1)
	case .SPHERE:   return mb.create_sphere_model(0.5)
	case .CYLINDER: return mb.create_cylinder_model(0.5, 1)
	case .PLANE:    return mb.create_plane_model(1)
	}
	return {}, .No_Geometry
}
