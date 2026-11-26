package matchbox

/*
	Skinned parts, cut to a target's joint limit
	============================================
	A skinned primitive's vertices each name up to four joints of the model's skin, and a draw can only
	carry mbi.skin_settings.joint_limit of them (22 on the 3DS: the vertex shader holds the palette in
	registers). So a primitive is cut into pieces, each a part of its own with a *joint map*: the skin's
	joints that piece uses, in the order its vertices' 8-bit `joints` name them. Classic matrix-palette
	skinning, done once at load (the build, on the handhelds) and never per frame.

	The cut is greedy over the triangles in file order: a triangle joins the open piece when the joints it
	adds still fit and starts a new one when they do not. A triangle alone needs at most 12 joints (three
	vertices of four), so any limit of 12 or more always succeeds. Nothing here touches the GPU or the file
	format, so the tests drive it with a synthetic rope. Free of glTF too: model_skin_load.odin reads the
	file and hands the numbers here.
*/

import "base:runtime"

/*What a glTF primitive's skinning looks like once read: per vertex, four skin joints and their weights*/
Skin_Influences :: struct {
	joints:[4]u16, // indices into the skin's joint list
	weights:[4]f32, // as the file has them; normalised here
}

/*One piece of a cut primitive. The caller owns the slices*/
Skinned_Piece :: struct {
	vertices:[]Skinned_Vertex,
	indices:[]u16,
	joint_map:[]u32,
}

/*
	Four influences as bytes that sum to 255. Weights are used as they arrive in the shader (a normalising
	divide on every vertex of every frame would fix something that cannot change after load), so the
	normalising happens here. A file may carry WEIGHTS_1, a second set of four that Matchbox does not read,
	so a vertex reaches here summing to less than one through no fault of the exporter; used unscaled it
	would land dragged toward the model's origin. A vertex with no weight at all is pinned to its first joint
	rather than collapsed. An influence of weight zero is pointed at the first real one's joint so that it
	adds nothing to the piece's joint map. The rounding error goes to the largest weight
*/
quantize_skin_influences :: proc(influences:Skin_Influences) -> (joints:[4]u16, weights:[4]u8) {
	total:f32
	first := -1
	for weight, index in influences.weights {
		if weight > 0 {
			total += weight
			if first < 0 do first = index
		}
	}
	if first < 0 || total <= 0 {
		return {influences.joints[0], influences.joints[0], influences.joints[0], influences.joints[0]}, {255, 0, 0, 0}
	}

	sum := 0
	largest := first
	for weight, index in influences.weights {
		scaled := weight / total if weight > 0 else 0
		weights[index] = u8(clamp(int(scaled * 255 + 0.5), 0, 255))
		sum += int(weights[index])
		joints[index] = influences.joints[index] if weight > 0 else influences.joints[first]
		if scaled > influences.weights[largest] / total do largest = index
	}
	weights[largest] = u8(int(weights[largest]) + 255 - sum)
	return
}

/*
	Cuts one primitive into pieces of at most `limit` joints. `vertices` are lit vertices (bind pose, in the
	mesh's space), `influences` one per vertex, `indices` the triangles. `skin_joint_count` is how many joints
	the skin has, which bounds the joints the influences may name. False when a triangle alone needs more
	than `limit` joints (a limit under 12) or an influence names a joint the skin does not have
*/
split_skinned_primitive :: proc(vertices:[]Lit_Vertex, influences:[]Skin_Influences, indices:[]u16, skin_joint_count:int, limit:int, allocator := context.allocator) -> (pieces:[]Skinned_Piece, ok:bool) {
	assert(len(vertices) == len(influences), "One set of influences per vertex")

	// Quantised once per vertex, not once per triangle that uses it
	joints := make([][4]u16, len(vertices), context.temp_allocator)
	weights := make([][4]u8, len(vertices), context.temp_allocator)
	for influence, index in influences {
		for slot in 0 ..< 4 {
			if influence.weights[slot] > 0 && int(influence.joints[slot]) >= skin_joint_count do return nil, false
		}
		joints[index], weights[index] = quantize_skin_influences(influence)
	}

	slot_of := make([]i32, max(skin_joint_count, 1), context.temp_allocator) // a skin joint -> its slot in the open piece, -1 if not in it
	for &slot in slot_of do slot = -1
	new_index := make([]i32, len(vertices), context.temp_allocator) // an original vertex -> its place in the open piece, -1 if not in it
	for &index in new_index do index = -1

	open_map := make([dynamic]u32, context.temp_allocator)
	open_vertices := make([dynamic]Skinned_Vertex, context.temp_allocator)
	open_sources := make([dynamic]u16, context.temp_allocator) // each open vertex's original index, to reset new_index with
	open_indices := make([dynamic]u16, context.temp_allocator)
	finished := make([dynamic]Skinned_Piece, allocator)

	close_piece :: proc(finished:^[dynamic]Skinned_Piece, open_map:^[dynamic]u32, open_vertices:^[dynamic]Skinned_Vertex, open_sources:^[dynamic]u16, open_indices:^[dynamic]u16, slot_of:[]i32, new_index:[]i32, allocator:runtime.Allocator) {
		if len(open_indices) == 0 do return
		piece := Skinned_Piece {
			vertices = make([]Skinned_Vertex, len(open_vertices), allocator),
			indices = make([]u16, len(open_indices), allocator),
			joint_map = make([]u32, len(open_map), allocator),
		}
		copy(piece.vertices, open_vertices[:])
		copy(piece.indices, open_indices[:])
		copy(piece.joint_map, open_map[:])
		append(finished, piece)

		for joint in open_map do slot_of[joint] = -1
		for source in open_sources do new_index[source] = -1
		clear(open_map)
		clear(open_vertices)
		clear(open_sources)
		clear(open_indices)
	}

	for corner := 0; corner + 2 < len(indices); corner += 3 {
		triangle := [3]u16{indices[corner], indices[corner + 1], indices[corner + 2]}

		// The joints this triangle needs that the open piece does not have yet
		missing:[12]u32
		missing_count := find_missing_joints(triangle, joints, weights, slot_of, &missing)
		if missing_count > limit {
			for piece in finished do delete_skinned_piece(piece, allocator)
			delete(finished)
			return nil, false
		}
		if len(open_map) + missing_count > limit {
			close_piece(&finished, &open_map, &open_vertices, &open_sources, &open_indices, slot_of, new_index, allocator)
			// A fresh piece has no joints, so the whole triangle's are missing
			missing_count = find_missing_joints(triangle, joints, weights, slot_of, &missing)
		}

		for joint in missing[:missing_count] {
			slot_of[joint] = i32(len(open_map))
			append(&open_map, joint)
		}
		for vertex in triangle {
			if new_index[vertex] < 0 {
				new_index[vertex] = i32(len(open_vertices))
				append(&open_sources, vertex)

				skinned := Skinned_Vertex{lit = vertices[vertex], weights = weights[vertex]}
				for slot in 0 ..< 4 {
					// A zero weight points at a joint that is in the map (quantize_skin_influences), or at the
					// first joint when the vertex has nothing at all; slot 0 is always valid then
					joint := joints[vertex][slot]
					if slot_of[joint] >= 0 {
						skinned.joints[slot] = u8(slot_of[joint])
					}
				}
				append(&open_vertices, skinned)
			}
			append(&open_indices, u16(new_index[vertex]))
		}
	}
	close_piece(&finished, &open_map, &open_vertices, &open_sources, &open_indices, slot_of, new_index, allocator)
	return finished[:], true
}

delete_skinned_piece :: proc(piece:Skinned_Piece, allocator := context.allocator) {
	delete(piece.vertices, allocator)
	delete(piece.indices, allocator)
	delete(piece.joint_map, allocator)
}

// The joints a triangle's weighted influences name that are not yet in the open piece (slot_of < 0), each once
@(private = "file")
find_missing_joints :: proc(triangle:[3]u16, joints:[][4]u16, weights:[][4]u8, slot_of:[]i32, missing:^[12]u32) -> (count:int) {
	for vertex in triangle {
		for slot in 0 ..< 4 {
			if weights[vertex][slot] == 0 do continue
			joint := u32(joints[vertex][slot])
			if slot_of[joint] >= 0 do continue
			already := false
			for existing in missing[:count] do if existing == joint do already = true
			if already == false {
				missing[count] = joint
				count += 1
			}
		}
	}
	return
}
