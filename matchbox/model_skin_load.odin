package matchbox

/*
	Loading -- skins and animation
	------------------------------
	The part of `load_model` that reads a skeleton out of a glTF file: the joint
	hierarchy, the inverse bind matrices, and the clips that move them.

	Kept beside `model_load.odin` rather than inside it because the two answer
	different questions. That file turns primitives into vertex buffers and is
	the whole of loading for a model with no skeleton; this one reads the parts
	of the format that only a character uses, and a game that never loads one
	pays for none of it.
*/

import "core:log"
import "core:math/linalg"
import "core:strings"

import sdl "vendor:sdl3"

import gltf "./gltf2"

// -----------------------------------------------------------------------
// The skeleton
// -----------------------------------------------------------------------

/*
	The node hierarchy, the rest pose, and every skin's joint list.

	Returns an empty skeleton for a file with no skins, which is most files and
	is not an error -- a campfire has no bones.

	The whole node array is kept, not just the joints. A joint's global
	transform is the product of everything above it, and what is above a joint
	is frequently not a joint: VRoid hangs its skeleton under a root node that
	no vertex is ever weighted to, and dropping it would lose the transform that
	stands the character up.

	`root_correction` exists for one caller: a VRM 0.0 file faces the wrong way
	for everything else in this package (see `vrm.odin`'s `vrm_facing_correction`),
	and it has to be baked in here rather than fixed up by the game, because a
	game has no seam to fix it at -- `sample_pose` overwrites a track's node
	outright and would erase a correction applied anywhere below this. Composed
	onto a root's own rotation rather than replacing it: a file with more than
	one root, or a root that is not already the identity, keeps whatever it had
	and turns in addition to it. Every other caller passes the identity and pays
	nothing -- a quaternion multiply by the identity is exact, not approximate.
*/
@(private)
build_skeleton :: proc(data: ^gltf.Data, root_correction := linalg.QUATERNIONF32_IDENTITY) -> Skeleton {
	if len(data.skins) == 0 do return Skeleton{}

	node_count := len(data.nodes)
	if node_count == 0 do return Skeleton{}

	skeleton := Skeleton{
		parents = make([]i32, node_count),
		rest    = make([]Transform, node_count),
		order   = make([]u32, 0),
		names   = make([]string, node_count),
		skins   = make([]Model_Skin, len(data.skins)),
	}

	for i in 0 ..< node_count do skeleton.parents[i] = -1

	for node, i in data.nodes {
		for child in node.children {
			if int(child) < node_count do skeleton.parents[child] = i32(i)
		}

		// Cloned for the same reason clip names are: the parser frees its own
		// strings when the document is unloaded, and that happens before
		// load_model returns.
		skeleton.names[i] = strings.clone(node.name.? or_else "")

		/*
			glTF gives a node either a matrix or a translation/rotation/scale
			triple, never both, and the parser defaults whichever is absent to
			the identity. Matchbox's animation works in TRS because that is what
			a channel drives -- there is no such thing as a keyframed matrix --
			so a node given as a matrix has to be taken apart.

			The common case is the cheap one: an animated node is written as TRS
			by every exporter, because a matrix cannot be interpolated
			meaningfully. The `transform_from_matrix` below is for the static
			nodes above the skeleton, which some exporters do write as matrices.
		*/
		if node.mat == linalg.MATRIX4F32_IDENTITY {
			skeleton.rest[i] = Transform{
				position = node.translation,
				rotation = node.rotation,
				scale    = node.scale,
			}
		} else {
			skeleton.rest[i] = transform_from_matrix(node.mat)
		}
	}

	apply_root_correction(&skeleton, root_correction)

	skeleton.order = hierarchy_order(skeleton.parents)

	for skin, i in data.skins {
		joints := make([]u32, len(skin.joints))
		for joint, j in skin.joints do joints[j] = u32(joint)

		inverse_bind := make([]matrix[4, 4]f32, len(skin.joints))
		for j in 0 ..< len(inverse_bind) do inverse_bind[j] = linalg.MATRIX4F32_IDENTITY

		/*
			The inverse bind matrices are optional in glTF, and their absence
			means every one of them is the identity -- a mesh already modelled
			in the skeleton's space. Rare, but legal, and the alternative to
			handling it is a character that vanishes with no message.
		*/
		if accessor, present := skin.inverse_bind_matrices.?; present {
			if matrices, ok := read_mat4(data, accessor); ok {
				copy(inverse_bind, matrices)
			}
		}

		/*
			The skin keeps every joint it declares, however many that is.

			This used to truncate to a fixed cap, which was right while a part's
			palette was the skin's palette and the palette lived in a
			4KB-limited Vulkan uniform. It is not any more: a part carries only
			the joints it uses (see `Model_Part.joint_map`), the palette is now
			an unbounded storage buffer, and truncating here left `skin.joints`
			too short for `animator_resolve` to look a compact slot back up --
			which silently left that palette entry a zero matrix, and a zero
			matrix collapses every vertex using it onto the origin.
		*/

		skeleton.skins[i] = Model_Skin{joints = joints, inverse_bind = inverse_bind}
	}

	return skeleton
}

/*
	Turns every root node an extra `correction` about its own rotation, in
	place.

	Split out of `build_skeleton` so it can be pinned down on a plain
	`Skeleton` in a test, with no `gltf.Data` to construct just to check a
	quaternion multiply -- see `vrm_test.odin`.

	A node's parent is not fully known until every other node has had a turn
	to name it as a child, so this runs as its own pass after `parents` is
	completely built rather than folded into the loop that builds it; a node
	that looks like a root partway through that loop can still gain a parent
	on a later iteration.

	Composed on the left of whatever rotation the node already had --
	world-space, applied after the node's own -- so the turn lands on the
	whole rig hanging off that root rather than only on its local axes. A
	multiskeleton file with more than one root turns every one of them the
	same way, which is what a file split into several independent armatures
	needs.
*/
@(private)
apply_root_correction :: proc(skeleton: ^Skeleton, correction: quaternion128) {
	if correction == linalg.QUATERNIONF32_IDENTITY do return

	for i in 0 ..< len(skeleton.parents) {
		if skeleton.parents[i] < 0 {
			skeleton.rest[i].rotation = correction * skeleton.rest[i].rotation
		}
	}
}

/*
	The nodes sorted so a parent always comes before its children.

	`animator_resolve` walks this to turn local transforms into global ones, and
	it needs the parent's answer finished before it starts the child's. glTF
	does not promise the node array is in that order -- and a file that happens
	to be would still be a file relying on luck.

	Breadth-first from the roots. A node whose parent index is out of range, or
	which sits in a cycle a malformed file created, is appended at the end
	rather than dropped: it is then resolved against whatever its parent last
	held, which is wrong but bounded, where leaving it out entirely would leave
	an uninitialised matrix in the palette.
*/
@(private)
hierarchy_order :: proc(parents: []i32) -> []u32 {
	order   := make([dynamic]u32, 0, len(parents))
	visited := make([]bool, len(parents), context.temp_allocator)

	// Freed through the allocator it came from. A slice does not carry its
	// allocator the way a map does, so a bare `delete` here hands a temp pointer
	// to the heap allocator -- which the default one tolerates and a tracking
	// allocator reports as a bad free, in a game that did nothing wrong.
	defer delete(visited, context.temp_allocator)

	for parent, i in parents {
		if parent < 0 {
			append(&order, u32(i))
			visited[i] = true
		}
	}

	// Each pass adds every node whose parent is already placed. Bounded by the
	// depth of the tree, which for a skeleton is single digits.
	for {
		added := false

		for parent, i in parents {
			if visited[i] do continue
			if parent < 0 || int(parent) >= len(parents) do continue
			if !visited[parent] do continue

			append(&order, u32(i))
			visited[i] = true
			added = true
		}

		if !added do break
	}

	if len(order) != len(parents) {
		log.errorf("model node hierarchy has %v unreachable nodes; the file's tree is malformed",
			len(parents) - len(order))
		for visit, i in visited {
			if !visit do append(&order, u32(i))
		}
	}

	return order[:]
}

// -----------------------------------------------------------------------
// The clips
// -----------------------------------------------------------------------

/*
	Every animation in the file, flattened from glTF's channels-and-samplers
	into one track per thing that moves.

	glTF splits a clip in two: a channel says which node and which property, a
	sampler says the times and the values. Nothing reads them separately, and
	keeping the split would mean an indirection per joint per frame, so they are
	joined here once instead.

	A clip's duration is the last time in any of its tracks. glTF does not store
	one -- it is implied by the keyframes, which means a clip whose tracks end at
	different times runs until the last of them does.
*/
@(private)
build_animations :: proc(data: ^gltf.Data) -> []Model_Animation {
	if len(data.animations) == 0 do return nil

	clips := make([]Model_Animation, len(data.animations))

	for animation, i in data.animations {
		tracks := make([dynamic]Animation_Track, 0, len(animation.channels))
		duration: f32

		for channel in animation.channels {
			node, has_node := channel.target.node.?
			if !has_node do continue // a channel targeting nothing, which is legal and inert

			if int(channel.sampler) >= len(animation.samplers) do continue
			sampler := animation.samplers[channel.sampler]

			path: Animation_Path
			switch channel.target.path {
			case .Translation: path = .TRANSLATION
			case .Rotation:    path = .ROTATION
			case .Scale:       path = .SCALE
			case .Weights:
				// Morph target weights. Matchbox skips morph targets at parse,
				// so there is nothing here for this to drive.
				continue
			}

			times, times_ok := read_scalars(data, sampler.input)
			if !times_ok || len(times) == 0 do continue

			track := Animation_Track{
				node  = u32(node),
				path  = path,
				times = times,
			}

			switch sampler.interpolation {
			case .Step:         track.interpolation = .STEP
			case .Cubic_Spline: track.interpolation = .CUBIC
			case .Linear:       fallthrough
			case:               track.interpolation = .LINEAR
			}

			if path == .ROTATION {
				values, ok := read_quaternions(data, sampler.output)
				if !ok do continue
				track.quats = values
			} else {
				// A real allocator, not temp: a clip outlives the load.
				values, ok := read_vec3(data, sampler.output, context.allocator)
				if !ok do continue
				track.vectors = values
			}

			duration = max(duration, times[len(times) - 1])
			append(&tracks, track)
		}

		name := animation.name.? or_else ""

		clips[i] = Model_Animation{
			// Cloned: the parser frees its own strings when the document is
			// unloaded, which happens before load_model returns.
			name     = strings.clone(name),
			duration = duration,
			tracks   = tracks[:],
		}
	}

	return clips
}

// -----------------------------------------------------------------------
// Accessors the rest of the loader does not need
// -----------------------------------------------------------------------

// Keyframe times. Owned rather than temp, because a clip outlives the load.
@(private)
read_scalars :: proc(data: ^gltf.Data, index: gltf.Integer) -> (out: []f32, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float keyframe times")
		return nil, false
	}

	out = make([]f32, count)
	for i in 0 ..< count do out[i] = (cast(^f32)&bytes[i * stride])^

	return out, true
}

/*
	Rotation keyframes.

	glTF writes a quaternion as x, y, z, w in that order, and Odin's
	`quaternion128` is constructed by naming its parts -- so the reorder happens
	here, once, rather than being a thing to remember at every use.

	Normalised on the way in. The spec requires unit quaternions and exporters
	honour it, but a rotation that is a thousandth long shrinks a limb slightly
	every frame it is slerped, and the fix costs one square root per keyframe at
	load rather than per joint per frame.
*/
@(private)
read_quaternions :: proc(data: ^gltf.Data, index: gltf.Integer) -> (out: []quaternion128, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float rotation keyframes")
		return nil, false
	}

	out = make([]quaternion128, count)
	for i in 0 ..< count {
		v := (cast(^[4]f32)&bytes[i * stride])^
		out[i] = linalg.quaternion_normalize(quaternion(x = v[0], y = v[1], z = v[2], w = v[3]))
	}

	return out, true
}

// Inverse bind matrices. glTF stores a matrix column by column, which is what
// Odin's matrix[4,4]f32 is too, so the sixteen floats copy straight across.
@(private)
read_mat4 :: proc(data: ^gltf.Data, index: gltf.Integer) -> (out: []matrix[4, 4]f32, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float inverse bind matrices")
		return nil, false
	}

	out = make([]matrix[4, 4]f32, count, context.temp_allocator)
	for i in 0 ..< count {
		floats := (cast(^[16]f32)&bytes[i * stride])^

		m: matrix[4, 4]f32
		for column in 0 ..< 4 {
			for row in 0 ..< 4 {
				m[row, column] = floats[column * 4 + row]
			}
		}
		out[i] = m
	}

	return out, true
}

/*
	Which joints move a vertex.

	glTF allows unsigned bytes or unsigned shorts, and exporters pick by joint
	count -- the VRoid model this was written against uses shorts for sixty-six
	joints, which it did not need to. Both are widened to u16, which is what the
	vertex layout declares.
*/
@(private)
read_joints :: proc(
	data: ^gltf.Data, attributes: map[string]gltf.Integer, count: int,
) -> [][4]u32 {
	out := make([][4]u32, count, context.temp_allocator)

	index, present := attributes["JOINTS_0"]
	if !present do return out

	bytes, stride, available, ok := accessor_span(data, index)
	if !ok do return out

	type := data.accessors[index].component_type

	for i in 0 ..< min(count, available) {
		at := &bytes[i * stride]

		switch type {
		case .Unsigned_Byte:
			raw := (cast(^[4]u8)at)^
			out[i] = {u32(raw[0]), u32(raw[1]), u32(raw[2]), u32(raw[3])}
		case .Unsigned_Short:
			raw := (cast(^[4]u16)at)^
			out[i] = {u32(raw[0]), u32(raw[1]), u32(raw[2]), u32(raw[3])}
		case .Byte, .Short, .Unsigned_Int, .Float:
			fallthrough
		case:
			log.error("unsupported joint index type")
			return out
		}
	}

	return out
}

/*
	How much say each of those four joints has.

	Floats, or normalised bytes or shorts -- the same compression glTF allows on
	texture coordinates, and for the same reason. A vertex with no weights at
	all gets `{1, 0, 0, 0}` rather than four zeroes, because four zeroes
	collapse the vertex onto the origin and take the triangle with it.

	**Renormalised on the way in, and that is not defensive tidying -- it is the
	fix for a real symptom.** The skinning shader builds `w0*M0 + w1*M1 +
	w2*M2 + w3*M3` and uses the result as-is; with the weights summing to `s`
	that puts the vertex at `s` times its correct model-space position, pulled
	toward the model's origin. glTF requires the four to sum to one, and the
	files that break it are not malformed -- they carry `WEIGHTS_1`, a *second*
	set of four influences that Matchbox does not read. A vertex with five
	influences therefore arrives here summing to less than one and lands short.

	The symptom is specific enough to name: on a character rig the origin sits
	on the ground between the feet, so a foot vertex with a fifth influence
	stays at ground level while the walk cycle lifts the foot around it. One
	vertex, stuck to the floor, and only while moving -- standing still it is
	already at origin height and nothing looks wrong.

	Normalising here rather than in the shader is deliberate: it is once at
	load instead of a divide on every vertex of every frame, and it is the same
	choice `read_quaternions` above already makes.
*/
@(private)
read_weights :: proc(
	data: ^gltf.Data, attributes: map[string]gltf.Integer, count: int,
) -> [][4]f32 {
	out := make([][4]f32, count, context.temp_allocator)
	for i in 0 ..< count do out[i] = {1, 0, 0, 0}

	index, present := attributes["WEIGHTS_0"]
	if !present do return out

	bytes, stride, available, ok := accessor_span(data, index)
	if !ok do return out

	type := data.accessors[index].component_type

	for i in 0 ..< min(count, available) {
		at := &bytes[i * stride]

		switch type {
		case .Float:
			out[i] = (cast(^[4]f32)at)^
		case .Unsigned_Byte:
			raw := (cast(^[4]u8)at)^
			out[i] = {f32(raw[0]) / 255, f32(raw[1]) / 255, f32(raw[2]) / 255, f32(raw[3]) / 255}
		case .Unsigned_Short:
			raw := (cast(^[4]u16)at)^
			out[i] = {f32(raw[0]) / 65535, f32(raw[1]) / 65535, f32(raw[2]) / 65535, f32(raw[3]) / 65535}
		case .Byte, .Short, .Unsigned_Int:
			fallthrough
		case:
			log.error("unsupported joint weight type")
			return out
		}
	}

	/*
		Say so when the file carries influences we are dropping.

		Renormalising below makes the mesh look right, but it is not what the
		artist authored: the fifth influence is gone and its say has been
		redistributed across the four that remain. That is a good trade and a
		bad silence, so it is reported once per primitive rather than left for
		somebody to find by eye.
	*/
	if _, more := attributes["WEIGHTS_1"]; more {
		log.warnf(
			"this mesh weights vertices to more than four joints; matchbox reads the first four and renormalises, so the rest are dropped")
	}

	// Renormalised so the four sum to one -- see the note above this
	// procedure for what an unnormalised set does to a vertex.
	for &w in out {
		sum := w[0] + w[1] + w[2] + w[3]

		// A vertex the file leaves entirely unweighted. Pinned to the first
		// joint rather than scaled to nothing, which is the same answer the
		// no-WEIGHTS_0 case above gives and for the same reason.
		if sum <= 0 {
			w = {1, 0, 0, 0}
			continue
		}

		if sum != 1 do w = {w[0] / sum, w[1] / sum, w[2] / sum, w[3] / sum}
	}

	return out
}

// -----------------------------------------------------------------------
// Uploading
// -----------------------------------------------------------------------

// `upload_mesh` for the wider vertex. The same two buffers; only the stride
// differs, and `upload_buffer` takes bytes and does not care.
@(private)
upload_skinned_mesh :: proc(
	vertices: []Vertex3D_Skinned,
	indices:  []u32,
	skin:     int,
	node:     u32,
) -> (Model_Part, Error) {
	vertex_buffer, vertex_err := upload_buffer(
		raw_data(vertices), u32(len(vertices) * size_of(Vertex3D_Skinned)), {.VERTEX})
	if vertex_err != nil do return {}, vertex_err

	index_buffer, index_err := upload_buffer(
		raw_data(indices), u32(len(indices) * size_of(u32)), {.INDEX})
	if index_err != nil {
		sdl.ReleaseGPUBuffer(mbi.renderer.device, vertex_buffer)
		return {}, index_err
	}

	return Model_Part{
		vertices    = vertex_buffer,
		indices     = index_buffer,
		index_count = u32(len(indices)),
		topology    = .TRIANGLES,
		skin        = skin,
		node        = node,
		material    = MATERIAL_DEFAULTS,
	}, nil
}

// -----------------------------------------------------------------------
// Freeing
// -----------------------------------------------------------------------

@(private)
destroy_skeleton :: proc(skeleton: ^Skeleton) {
	for &skin in skeleton.skins {
		delete(skin.joints)
		delete(skin.inverse_bind)
	}

	for name in skeleton.names do delete(name)
	delete(skeleton.names)

	delete(skeleton.skins)
	delete(skeleton.order)
	delete(skeleton.rest)
	delete(skeleton.parents)

	skeleton^ = Skeleton{}
}

@(private)
destroy_animations :: proc(animations: []Model_Animation) {
	for clip in animations {
		for track in clip.tracks {
			delete(track.times)
			delete(track.vectors)
			delete(track.quats)
		}
		delete(clip.tracks)
		delete(clip.name)
	}

	delete(animations)
}

// Silences the unused-import warning on a file that only borrows sdl through
// upload_buffer's return type.
_ :: sdl
