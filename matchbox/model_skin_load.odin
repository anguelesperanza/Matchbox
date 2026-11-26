#+build windows

package matchbox

/*
	Model -- loading skins and animation from glTF (PC)
	===================================================
	The part of read_gltf_model that only a character uses: the node hierarchy and its rest pose, each
	skin's joint list and inverse bind matrices, the clips, and a skinned primitive's joints and weights.
	Kept beside model_load_windows.odin because the two answer different questions. That file turns
	primitives into vertex buffers; this one reads what a skeleton adds. A model with no skin pays for none
	of it: build_gltf_skeleton returns an empty one.

	Two facts about glTF decide the shape of this:
	- A skinned mesh ignores the transform of the node it hangs off, so a skinned primitive's vertices are
	  NOT baked into the model's space the way an unskinned part's are. They stay in the mesh's own space and
	  the palette (skeleton.odin) carries them to where the pose puts them.
	- The skeleton keeps every node, not only the joints. What is above a joint is frequently not a joint
	  (VRoid hangs its skeleton under a root nothing is weighted to), and dropping it would lose the
	  transform that stands the character up.
*/

import "core:math/linalg"
import "core:strings"

import gltf "./gltf2"

/*
	The node hierarchy, rest pose and every skin of a file. An empty skeleton for a file with no skins, which
	is most files and is not an error: a campfire has no bones
*/
@(private)
build_gltf_skeleton :: proc(file:^gltf.Data) -> Skeleton {
	if len(file.skins) == 0 || len(file.nodes) == 0 do return {}

	node_count := len(file.nodes)
	skeleton := Skeleton {
		parents = make([]i32, node_count),
		rest = make([]Transform, node_count),
		names = make([]string, node_count),
		skins = make([]Model_Skin, len(file.skins)),
	}
	for &parent in skeleton.parents do parent = -1

	for node, index in file.nodes {
		for child in node.children {
			if int(child) < node_count do skeleton.parents[child] = i32(index)
		}
		// Cloned: the parser frees its own strings when the document is unloaded, before load_model returns
		skeleton.names[index] = strings.clone(node.name.? or_else "")
		skeleton.rest[index] = calculate_gltf_node_transform(node)
	}
	skeleton.order = calculate_skeleton_order(skeleton.parents)

	for skin, index in file.skins {
		joints := make([]u32, len(skin.joints))
		for joint, slot in skin.joints do joints[slot] = u32(joint)
		binds := make([]matrix[4, 4]f32, len(skin.joints))
		for &bind in binds do bind = linalg.MATRIX4F32_IDENTITY

		if accessor, has_binds := skin.inverse_bind_matrices.?; has_binds {
			if bytes, stride, count, ok := read_gltf_accessor(file, accessor); ok && file.accessors[accessor].component_type == .Float {
				for slot in 0 ..< min(count, len(binds)) do binds[slot] = (cast(^matrix[4, 4]f32)&bytes[slot * stride])^
			}
		}
		skeleton.skins[index] = Model_Skin{joints = joints, inverse_bind = binds}
	}
	return skeleton
}

/*
	A node's own transform as translation, rotation and scale. glTF gives either a matrix or the three, and the
	parser defaults the absent one to the identity. Animation works in TRS, so a node given as a matrix is taken
	apart; one given as TRS is used as it is
*/
@(private)
calculate_gltf_node_transform :: proc(node:gltf.Node) -> Transform {
	if node.mat != linalg.MATRIX4F32_IDENTITY {
		m := node.mat
		column_x := [3]f32{m[0, 0], m[1, 0], m[2, 0]}
		column_y := [3]f32{m[0, 1], m[1, 1], m[2, 1]}
		column_z := [3]f32{m[0, 2], m[1, 2], m[2, 2]}
		scale := [3]f32{linalg.length(column_x), linalg.length(column_y), linalg.length(column_z)}
		rotation_matrix := matrix[3, 3]f32 {
			m[0, 0] / scale.x, m[0, 1] / scale.y, m[0, 2] / scale.z,
			m[1, 0] / scale.x, m[1, 1] / scale.y, m[1, 2] / scale.z,
			m[2, 0] / scale.x, m[2, 1] / scale.y, m[2, 2] / scale.z,
		}
		return Transform{position = {m[0, 3], m[1, 3], m[2, 3]}, rotation = linalg.quaternion_from_matrix3(rotation_matrix), scale = scale}
	}
	return Transform {
		position = {f32(node.translation.x), f32(node.translation.y), f32(node.translation.z)},
		rotation = quaternion(x = f32(imag(node.rotation)), y = f32(jmag(node.rotation)), z = f32(kmag(node.rotation)), w = f32(real(node.rotation))),
		scale = {f32(node.scale.x), f32(node.scale.y), f32(node.scale.z)},
	}
}

/*
	Every clip of the file: per channel, one track of times and values. Channels that drive morph targets
	(`weights`), or a node the file does not have, or values that are not floats, are skipped
*/
@(private)
build_gltf_animations :: proc(file:^gltf.Data) -> []Model_Animation {
	if len(file.animations) == 0 do return nil

	clips := make([]Model_Animation, len(file.animations))
	for source, clip_index in file.animations {
		tracks := make([dynamic]Animation_Track)
		clip := &clips[clip_index]
		clip.name = strings.clone(source.name.? or_else "")

		for channel in source.channels {
			node, has_node := channel.target.node.?
			if has_node == false || int(node) >= len(file.nodes) || channel.target.path == .Weights do continue
			if int(channel.sampler) >= len(source.samplers) do continue
			sampler := source.samplers[channel.sampler]

			times, times_ok := read_gltf_scalars(file, sampler.input)
			if times_ok == false || len(times) == 0 do continue

			track := Animation_Track{node = u32(node), times = times}
			switch sampler.interpolation {
			case .Linear: track.interpolation = .LINEAR
			case .Step: track.interpolation = .STEP
			case .Cubic_Spline: track.interpolation = .CUBIC
			}
			per_key := 3 if track.interpolation == .CUBIC else 1

			#partial switch channel.target.path {
			case .Translation, .Scale:
				track.path = .TRANSLATION if channel.target.path == .Translation else .SCALE
				values, ok := read_gltf_vec3_owned(file, sampler.output)
				if ok == false || len(values) != len(times) * per_key {
					delete(values)
					delete(times)
					continue
				}
				track.vectors = values
			case .Rotation:
				track.path = .ROTATION
				values, ok := read_gltf_quats_owned(file, sampler.output)
				if ok == false || len(values) != len(times) * per_key {
					delete(values)
					delete(times)
					continue
				}
				track.quats = values
			}
			clip.duration = max(clip.duration, times[len(times) - 1])
			append(&tracks, track)
		}
		clip.tracks = tracks[:]
	}
	return clips
}

@(private)
read_gltf_scalars :: proc(file:^gltf.Data, index:gltf.Integer) -> (values:[]f32, ok:bool) {
	bytes, stride, count := read_gltf_accessor(file, index) or_return
	if file.accessors[index].component_type != .Float do return nil, false
	values = make([]f32, count)
	for i in 0 ..< count do values[i] = (cast(^f32)&bytes[i * stride])^
	return values, true
}

@(private)
read_gltf_vec3_owned :: proc(file:^gltf.Data, index:gltf.Integer) -> (values:[][3]f32, ok:bool) {
	bytes, stride, count := read_gltf_accessor(file, index) or_return
	if file.accessors[index].component_type != .Float do return nil, false
	values = make([][3]f32, count)
	for i in 0 ..< count do values[i] = (cast(^[3]f32)&bytes[i * stride])^
	return values, true
}

/*Quaternions as x, y, z, w floats, which is glTF's order and what quaternion(x =, ...) takes*/
@(private)
read_gltf_quats_owned :: proc(file:^gltf.Data, index:gltf.Integer) -> (values:[]quaternion128, ok:bool) {
	bytes, stride, count := read_gltf_accessor(file, index) or_return
	if file.accessors[index].component_type != .Float do return nil, false
	values = make([]quaternion128, count)
	for i in 0 ..< count {
		xyzw := (cast(^[4]f32)&bytes[i * stride])^
		values[i] = quaternion(x = xyzw.x, y = xyzw.y, z = xyzw.z, w = xyzw.w)
	}
	return values, true
}

/*
	A primitive's JOINTS_0 and WEIGHTS_0 as influences, one per vertex. Joints are bytes or shorts; weights
	are floats or normalised bytes or shorts. False when either is missing or not one of those
*/
@(private)
read_gltf_influences :: proc(file:^gltf.Data, attributes:map[string]gltf.Integer, count:int) -> (influences:[]Skin_Influences, ok:bool) {
	joints_accessor, has_joints := attributes["JOINTS_0"]
	weights_accessor, has_weights := attributes["WEIGHTS_0"]
	if has_joints == false || has_weights == false do return nil, false

	joint_bytes, joint_stride, joint_count, joints_ok := read_gltf_accessor(file, joints_accessor)
	weight_bytes, weight_stride, weight_count, weights_ok := read_gltf_accessor(file, weights_accessor)
	if joints_ok == false || weights_ok == false || joint_count < count || weight_count < count do return nil, false

	influences = make([]Skin_Influences, count, context.temp_allocator)
	for i in 0 ..< count {
		joint_at := &joint_bytes[i * joint_stride]
		weight_at := &weight_bytes[i * weight_stride]
		for slot in 0 ..< 4 {
			#partial switch file.accessors[joints_accessor].component_type {
			case .Unsigned_Byte: influences[i].joints[slot] = u16((cast([^]u8)joint_at)[slot])
			case .Unsigned_Short: influences[i].joints[slot] = (cast([^]u16)joint_at)[slot]
			case: return nil, false
			}
			#partial switch file.accessors[weights_accessor].component_type {
			case .Float: influences[i].weights[slot] = (cast([^]f32)weight_at)[slot]
			case .Unsigned_Byte: influences[i].weights[slot] = f32((cast([^]u8)weight_at)[slot]) / 255
			case .Unsigned_Short: influences[i].weights[slot] = f32((cast([^]u16)weight_at)[slot]) / 65535
			case: return nil, false
			}
		}
	}
	return influences, true
}
