package level

/*
	Instances
	---------
	A level with forty crates in it writes the crate's path, tint and shadow
	flag forty times. An instance is that written once, under an id, with each
	crate keeping only its transform and which instance it is. Stargate's
	`level_editor_plan.md` section 5.17 is the design.

	**Instancing is a shape the file is written in, not a shape the level is
	held in.** A level in memory always has a whole `Model_Component` on every
	entity that draws something: `pack_instances` folds the repeats together on
	the way out and `expand_instances` undoes it on the way in, and nothing
	between the two ever has to ask whether an entity is an instance. So:

	- every reader in this package and in the editor -- drawing, picking,
	  bounds, undo, duplicating -- is unchanged, because what it reads is
	  unchanged
	- a level written with instancing and read back is the same level, field
	  for field. `test_instancing_round_trips` asserts exactly that
	- turning instancing off and saving again writes the long form, and the
	  level is still the same level

	*Alternative:* holding the instance reference on the entity all the way
	through, so an entity is either "its own model" or "instance 3". That is
	what a scene graph built round instances looks like, and it would let the
	editor change forty crates' tint in one place. Rejected for now because it
	puts a second way of saying where an entity's model comes from into every
	reader, for a saving the file gets either way -- and because the thing it
	buys, editing a whole group at once, is a feature nobody has asked for yet.

	**One model per path was already true.** The asset table in `Level_Runtime`
	loads each path once however many entities name it, so the forty crates
	shared one `mb.Model` on the GPU before any of this. Instancing is about the
	bytes on disk and about saying, in the file, that the forty are the same
	thing.

	**What counts as the same.** Two entities share an instance when their model
	components are equal in every saved field -- path, tint, and whether they
	cast a shadow -- and neither is marked `unique`. A crate tinted red is
	therefore its own instance, or its own long-form entry, rather than quietly
	becoming a white one.

	*Alternative:* grouping on the path alone, and leaving the tint and the
	shadow flag on each entity -- which is what "instance" means in a renderer,
	where the per-instance data is exactly the part that varies. **Measured, and
	rejected:** Odin's pretty marshal writes every field of every struct, so an
	entity that keeps a tint keeps six lines of it either way, and dropping only
	the path line while gaining an `instance` line saves nothing at all. The
	saving comes entirely from omitting the whole component, and that is only
	honest when the instance really does say everything about it.

	**What it is worth, measured on real files:**

	- forty identical walls, which is what one drag of the path tool makes:
	  24,972 bytes down to 17,949, or 71.9% -- one instance, and the level reads
	  back identical field for field
	- `examples/walk-level`'s yard: 11,552 bytes, unchanged, no instances. Its
	  seventeen entities are one generated cube tinted seventeen different ways
	  to stand in for seventeen models, so no two of them are the same thing.
	  That is the rule above working, not failing -- but it is worth knowing
	  that instancing buys nothing on a level with no repeats in it.
*/

import "core:fmt"
import "core:strings"

/*
	One model component written once, for every entity that refers to it.

	`id` is unique within a level's instance list and has nothing to do with an
	entity id -- it is only ever read by `Model_Component.instance` in the same
	file. Ids start at 1, so 0 keeps meaning "no instance" the way it does for
	`Entity.parent`.
*/
Instance_Source :: struct {
	id:    u64,
	model: Model_Component,
}

/*
	`level` with every repeated model component lifted into `instances`, ready
	to marshal. The copy shares the original's strings -- it is written and
	thrown away within `save_level`, and freeing it would free the level's own
	names.

	Entities keep their order and their ids; only their model components change,
	and only by losing the fields the instance now holds.
*/
pack_instances :: proc(level: Level, allocator := context.temp_allocator) -> Level {
	packed := level
	packed.instances = make([dynamic]Instance_Source, allocator)
	packed.entities  = make([dynamic]Entity, 0, len(level.entities), allocator)

	// How many entities want each distinct component, so that a component used
	// once is left where it is: an instance holding a single entity is a longer
	// file, not a shorter one.
	shared := make(map[string]int, len(level.entities), allocator)
	defer delete(shared)

	for entity in level.entities {
		model, has_model := entity.model.?
		if !has_model || model.unique do continue
		shared[instance_key(model, allocator)] += 1
	}

	// Which instance id a key was given, once it earns one.
	ids := make(map[string]u64, len(shared), allocator)
	defer delete(ids)

	next_id: u64 = 1

	for entity in level.entities {
		kept := entity

		// An id left over from the file this level was read out of would name a
		// different group in *this* file, since the ids are handed out afresh
		// below. So every entity starts with none, and only folding gives it one.
		kept.instance = 0

		if model, has_model := entity.model.?; has_model && !model.unique {
			key := instance_key(model, allocator)

			if shared[key] > 1 {
				id, already := ids[key]
				if !already {
					id = next_id
					next_id += 1
					ids[key] = id
					append(&packed.instances, Instance_Source{id = id, model = model})
				}

				// The component goes entirely: what is left is a null model and
				// the reference, which is the whole point. An emptied component
				// would still write every key it has.
				kept.model    = nil
				kept.instance = id
			}
		}

		append(&packed.entities, kept)
	}

	return packed
}

/*
	Puts back what `pack_instances` took out: every entity whose model component
	names an instance gets that instance's component, keeping its own `instance`
	id so that saving again without instancing is still the same level.

	`problems` gains a line for an entity naming an instance that is not in the
	file -- that entity draws nothing rather than drawing the wrong thing, which
	is the smallest repair that lets the rest load.

	The components' paths are cloned with `allocator`, because one instance
	serves many entities and `destroy_level` frees a path per entity.
*/
expand_instances :: proc(level: ^Level, problems: ^[dynamic]string, allocator := context.allocator) {
	// No early return on an empty instance list: an entity naming an instance in
	// a file that has none is exactly the case worth reporting, and the loop
	// below costs one comparison per entity when there is nothing to do.
	sources := make(map[u64]Model_Component, len(level.instances), context.temp_allocator)
	defer delete(sources)

	for source in level.instances {
		if source.id == 0 do continue
		sources[source.id] = source.model
	}

	for &entity, i in level.entities {
		if entity.instance == 0 do continue

		// A file with both is one someone edited by hand. The component written
		// out is the more specific of the two, so it wins and the reference is
		// dropped, rather than the instance quietly replacing it.
		if _, has_model := entity.model.?; has_model {
			if problems != nil {
				append(problems, fmt.aprintf(
					"entities[%d] %q: has a model of its own as well as instance %d; its own is used",
					i, entity.name, entity.instance, allocator = allocator))
			}
			entity.instance = 0
			continue
		}

		source, found := sources[entity.instance]
		if !found {
			if problems != nil {
				append(problems, fmt.aprintf(
					"entities[%d] %q: instance %d is not in the file; it draws nothing",
					i, entity.name, entity.instance, allocator = allocator))
			}
			entity.instance = 0
			continue
		}

		// Its own copy of the path: one instance serves many entities, and
		// `destroy_level` frees a path per entity.
		model := source
		model.path   = strings.clone(source.path, allocator)
		entity.model = model
	}

	// The sources' own paths belong to the unmarshalled instance list, which
	// `destroy_level` frees separately; the entities have their own copies now.
	// The ids stay on the entities: they are what says these were one group, and
	// packing again hands out the same ids in the same order.
}

// The text two model components have in common exactly when they may share an
// instance. A key rather than a comparison, so the grouping is one map lookup
// per entity instead of a scan of everything grouped so far.
@(private)
instance_key :: proc(model: Model_Component, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s|%v|%v", model.path, model.tint, model.casts_shadow, allocator = allocator)
}
