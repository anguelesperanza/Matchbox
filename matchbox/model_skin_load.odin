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
*/
@(private)
build_skeleton :: proc(data: ^gltf.Data) -> Skeleton {
	if len(data.skins) == 0 do return Skeleton{}

	node_count := len(data.nodes)
	if node_count == 0 do return Skeleton{}

	skeleton := Skeleton{
		parents = make([]i32, node_count),
		rest    = make([]Transform, node_count),
		order   = make([]u32, 0),
		skins   = make([]Model_Skin, len(data.skins)),
	}

	for i in 0 ..< node_count do skeleton.parents[i] = -1

	for node, i in data.nodes {
		for child in node.children {
			if int(child) < node_count do skeleton.parents[child] = i32(i)
		}

		/*
			glTF gives a node either a matrix or a translation/rotation/scale
			triple, never both, and the parser defaults whichever is absent to
			the identity. Matchbox's animation works in TRS because that is what
			a channel drives -- there is no such thing as a keyframed matrix --
			so a node given as a matrix has to be taken apart.

			The common case is the cheap one: an animated node is written as TRS
			by every exporter, because a matrix cannot be interpolated
			meaningfully. The decompose below is for the static nodes above the
			skeleton, which some exporters do write as matrices.
		*/
		if node.mat == linalg.MATRIX4F32_IDENTITY {
			skeleton.rest[i] = Transform{
				position = node.translation,
				rotation = node.rotation,
				scale    = node.scale,
			}
		} else {
			skeleton.rest[i] = decompose(node.mat)
		}
	}

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

		if len(joints) > MAX_JOINTS {
			log.errorf("skin has %v joints, more than MAX_JOINTS (%v); the excess are dropped and the mesh will tear",
				len(joints), MAX_JOINTS)
			joints       = joints[:MAX_JOINTS]
			inverse_bind = inverse_bind[:MAX_JOINTS]
		}

		skeleton.skins[i] = Model_Skin{joints = joints, inverse_bind = inverse_bind}
	}

	return skeleton
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
	defer delete(visited)

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

/*
	A matrix back into the translation, rotation and scale it was built from.

	Only for the static nodes above a skeleton -- an animated node is always
	written as TRS. Assumes no shear, which is true of anything an exporter
	produces from a transform hierarchy.
*/
@(private)
decompose :: proc(m: matrix[4, 4]f32) -> Transform {
	position := [3]f32{m[0, 3], m[1, 3], m[2, 3]}

	x := [3]f32{m[0, 0], m[1, 0], m[2, 0]}
	y := [3]f32{m[0, 1], m[1, 1], m[2, 1]}
	z := [3]f32{m[0, 2], m[1, 2], m[2, 2]}

	scale := [3]f32{linalg.length(x), linalg.length(y), linalg.length(z)}

	// A mirrored transform has a negative determinant, which cannot be
	// expressed as a rotation. Folding it into x keeps the handedness rather
	// than silently turning the node inside out.
	if linalg.determinant(m) < 0 do scale.x = -scale.x

	rotation := linalg.QUATERNIONF32_IDENTITY
	if scale.x != 0 && scale.y != 0 && scale.z != 0 {
		basis := matrix[3, 3]f32{
			x.x / scale.x, y.x / scale.y, z.x / scale.z,
			x.y / scale.x, y.y / scale.y, z.y / scale.z,
			x.z / scale.x, y.z / scale.y, z.z / scale.z,
		}
		rotation = linalg.quaternion_from_matrix3_f32(basis)
	}

	return Transform{position = position, rotation = rotation, scale = scale}
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
				values, ok := read_vec3_owned(data, sampler.output)
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

// Translations and scales, and the tangents either side of them under a cubic
// sampler. Owned, unlike `read_vec3`, which is temp because a vertex buffer
// takes a copy immediately.
@(private)
read_vec3_owned :: proc(data: ^gltf.Data, index: gltf.Integer) -> (out: [][3]f32, ok: bool) {
	bytes, stride, count := accessor_span(data, index) or_return

	if data.accessors[index].component_type != .Float {
		log.error("expected float animation values")
		return nil, false
	}

	out = make([][3]f32, count)
	for i in 0 ..< count do out[i] = (cast(^[3]f32)&bytes[i * stride])^

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
) -> [][4]u16 {
	out := make([][4]u16, count, context.temp_allocator)

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
			out[i] = {u16(raw[0]), u16(raw[1]), u16(raw[2]), u16(raw[3])}
		case .Unsigned_Short:
			out[i] = (cast(^[4]u16)at)^
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
) -> Model_Part {
	return Model_Part{
		vertices = upload_buffer(
			raw_data(vertices), u32(len(vertices) * size_of(Vertex3D_Skinned)), {.VERTEX}),
		indices = upload_buffer(
			raw_data(indices), u32(len(indices) * size_of(u32)), {.INDEX}),
		index_count = u32(len(indices)),
		topology    = .TRIANGLES,
		skin        = skin,
		node        = node,
	}
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
