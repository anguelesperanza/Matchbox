package matchbox

/*
	Skin
	====
	What the renderer needs to draw a skinned part, shared by every target: the vertex it draws, the
	per-target joint limit, and the frame's joint arena that render_model fills and camera_end reads.

	**The joint limit is a setting, per target, and a "revisit later" one.** 256 on the PC, 64 on the Vita,
	22 on the 3DS (96 float registers, three per joint after the lighting and matrices take theirs:
	docs/g6_skinned_animation_plan.md). The user plans a PC-only pass that raises the PC figure at the cost of a
	model that does not compile to the other targets, so the number lives in `mbi.skin_settings`
	(Backend_State, filled in BACKEND_DEFAULTS), never in shared code. The loader splits a part so it uses at
	most that many joints, and the shaders' JOINT_SLOT_COUNT is the same number per target.
*/

/*
	A vertex of a skinned mesh: a Lit_Vertex whole (48 bytes, so the lit shaders' first four attributes read
	it unchanged) and then the four joints that move it and how much each has a say (56 bytes). `joints`
	index the *part's* joint_map, not the skin's joint list, and 8 bits cover any limit above. `weights`
	are 0..255 for 0..1, summing to 255 after the loader has finished with them
*/
Skinned_Vertex :: struct {
	using lit:Lit_Vertex,
	joints:[4]u8,
	weights:[4]u8,
}

/*Fixed values the engine uses for skinning, held in mbi.skin_settings (written in each backend's BACKEND_DEFAULTS)*/
Skin_Settings :: struct {
	joint_limit:int, // the most joints one draw may use: 256 PC, 64 Vita, 22 3DS. A target's own, revisit later (see above)
	// The most animation layers an animator works on top of its base clip: 4 PC, 2 Vita, 2 3DS. A layer is a second pass over every
	// masked joint on the CPU, which the handhelds' soft-float cores feel (docs/g6_skinned_animation_plan.md, the layer addendum).
	// A target's own, revisit later once measured on hardware. At most MAX_ANIMATION_LAYERS, the size of the array
	layer_limit:int,
}

/*
	The frame's joints, three rows of four floats each (a skin matrix's last row is always 0 0 0 1), back to
	back for every skinned draw queued since camera_start. A draw names its slice by `joint_offset` and
	`joint_count` (in joints). Cleared at camera_end, so an animator updated again before then, or a model drawn
	twice with two animators, each leaves its own copy
*/
Skin_State :: struct {
	rows:[dynamic][4]f32,
}

/*
	Copies `palette` (one matrix per joint of a part's joint_map) into the arena and returns where it landed:
	the first joint's index, and how many. A palette longer than the limit is a loader bug, so it is refused
*/
@(private)
push_skin_palette :: proc(palette:[]matrix[4, 4]f32) -> (offset, count:int) {
	ensure(len(palette) <= mbi.skin_settings.joint_limit, "A part uses more joints than this target allows")
	offset = len(mbi.skin_state.rows) / 3
	for matrix_ in palette {
		append(&mbi.skin_state.rows, [4]f32{matrix_[0, 0], matrix_[0, 1], matrix_[0, 2], matrix_[0, 3]})
		append(&mbi.skin_state.rows, [4]f32{matrix_[1, 0], matrix_[1, 1], matrix_[1, 2], matrix_[1, 3]})
		append(&mbi.skin_state.rows, [4]f32{matrix_[2, 0], matrix_[2, 1], matrix_[2, 2], matrix_[2, 3]})
	}
	return offset, len(palette)
}

/*
	The rows of draw `item`'s joints laid out as the shaders' `skin` block has them: all the first rows, then all
	the second, then all the third (`row0`, `row1`, `row2`, `limit` of each), padded to the target's limit with the
	identity. An empty palette is the identity throughout, which is a skinned model drawn with no animator: its bind
	pose. Row arrays rather than a joint's three rows together, because the 3DS indexes with an address register
	and has no arithmetic to scale the index (docs/g6_skinned_animation_plan.md)
*/
@(private)
get_skin_rows :: proc(item:Render_Item, allocator := context.temp_allocator) -> [][4]f32 {
	limit := mbi.skin_settings.joint_limit
	rows := make([][4]f32, limit * 3, allocator)
	for joint in 0 ..< limit {
		rows[joint] = {1, 0, 0, 0}
		rows[limit + joint] = {0, 1, 0, 0}
		rows[2 * limit + joint] = {0, 0, 1, 0}
	}
	if item.joint_count > 0 {
		count := min(item.joint_count, limit)
		for joint in 0 ..< count {
			source := (item.joint_offset + joint) * 3
			rows[joint] = mbi.skin_state.rows[source]
			rows[limit + joint] = mbi.skin_state.rows[source + 1]
			rows[2 * limit + joint] = mbi.skin_state.rows[source + 2]
		}
	}
	return rows
}
