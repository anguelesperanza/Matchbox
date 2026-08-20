package matchbox

/*
	Maths -- 3D
	-----------
	The transforms a 3D draw needs, and the one convention that has to be right
	for any of the rest to work.

	**Matchbox writes its own projections rather than taking the ones in
	core:math/linalg.** linalg's map the frustum to clip z in [-1, 1], which is
	the OpenGL convention. SDL3_GPU normalises to the D3D one -- clip z in
	[0, 1] -- on every backend including Vulkan, the same way it normalises y so
	that +1 is the top. Handing it a GL matrix does not fail and does not warn.
	It throws away everything between the near plane and the middle of the
	frustum, so close geometry vanishes and what is left depth-tests against
	nothing, which reads as a loading bug rather than a matrix bug.

	Everything else is linalg's -- vectors, quaternions, the matrix type itself.
	None of that carries a convention this has to agree with.

	Right handed, +y up, camera looking down -z. That is what glTF assumes and
	what both games were written against.
*/

import "core:math"
import "core:math/linalg"

// -----------------------------------------------------------------------
// Transform
// -----------------------------------------------------------------------

/*
	Where a model is, which way it is turned, and how big it is.

	**The zero value is not the identity.** A zeroed Transform has a scale of
	zero and a rotation that is not a rotation, and a model drawn with one is a
	model you cannot see. `transform_identity()` is the one to start from, and
	`draw_model_at` exists so that the common case -- a position and a uniform
	scale -- never has to build one at all.

	Rotation is a quaternion because that is what the physics library hands
	back. `b3.Body_GetRotation` returns one directly, so a body's orientation
	reaches a draw call without being taken apart into angles and put back
	together again.
*/
Transform :: struct {
	position: [3]f32,
	rotation: quaternion128,
	scale:    [3]f32,
}

// A Transform that does nothing: at the origin, unturned, full size.
transform_identity :: proc() -> Transform {
	return Transform{
		position = {0, 0, 0},
		rotation = linalg.QUATERNIONF32_IDENTITY,
		scale    = {1, 1, 1},
	}
}

// A Transform at `position`, turned by `rotation`, at one scale on every axis.
transform_at :: proc(position: [3]f32, rotation := linalg.QUATERNIONF32_IDENTITY, scale: f32 = 1) -> Transform {
	return Transform{
		position = position,
		rotation = rotation,
		scale    = {scale, scale, scale},
	}
}

// Turn about an axis, in radians. `b3.GetAxisAngle` gives both arguments.
transform_rotation :: proc(axis: [3]f32, angle_radians: f32) -> quaternion128 {
	return linalg.quaternion_angle_axis_f32(angle_radians, linalg.normalize(axis))
}

// Scale, then rotate, then translate -- the order that turns a model about its
// own centre rather than swinging it around the origin.
transform_matrix :: proc(t: Transform) -> matrix[4, 4]f32 {
	s := matrix[4, 4]f32{
		t.scale.x, 0,         0,         0,
		0,         t.scale.y, 0,         0,
		0,         0,         t.scale.z, 0,
		0,         0,         0,         1,
	}

	r := linalg.matrix4_from_quaternion_f32(t.rotation)

	tr := matrix[4, 4]f32{
		1, 0, 0, t.position.x,
		0, 1, 0, t.position.y,
		0, 0, 1, t.position.z,
		0, 0, 0, 1,
	}

	return tr * r * s
}

// -----------------------------------------------------------------------
// Projection
// -----------------------------------------------------------------------

/*
	A perspective projection with a [0, 1] depth range.

	`fov_degrees` is the vertical field of view. Degrees, not radians, unlike
	the rotations elsewhere in Matchbox: this is a number a person types, and
	70 is a field of view where 1.22 is a puzzle. Both games already write 70
	and 60.

	The [0, 1] range is the whole reason this is written out rather than
	imported. See the note at the top of this file.
*/
perspective :: proc(fov_degrees, aspect, near, far: f32) -> matrix[4, 4]f32 {
	f := 1 / math.tan(math.to_radians(fov_degrees) * 0.5)

	m: matrix[4, 4]f32
	m[0, 0] = f / aspect
	m[1, 1] = f
	m[2, 2] = far / (near - far)
	m[2, 3] = near * far / (near - far)
	m[3, 2] = -1

	return m
}

// An orthographic projection, also [0, 1] in depth. Same reasoning as above.
ortho :: proc(left, right, bottom, top, near, far: f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32
	m[0, 0] = 2 / (right - left)
	m[1, 1] = 2 / (top - bottom)
	m[2, 2] = 1 / (near - far)
	m[0, 3] = -(right + left) / (right - left)
	m[1, 3] = -(top + bottom) / (top - bottom)
	m[2, 3] = near / (near - far)
	m[3, 3] = 1

	return m
}

/*
	A view matrix for an eye looking at a point.

	Not part of the 2D `look_at` group, which answers a different question --
	that one returns the angle to turn a sprite by, this returns a matrix that
	moves the whole world in front of a camera.

	A view matrix carries no depth convention, so this agrees with linalg's
	`matrix4_look_at`. It is written out anyway to keep the three transforms
	that make up a camera in one place and readable together.
*/
look_at_matrix :: proc(eye, target, up: [3]f32) -> matrix[4, 4]f32 {
	f := linalg.normalize(target - eye) // forward, the way the camera faces
	s := linalg.normalize(linalg.cross(f, up)) // sideways, to the right
	u := linalg.cross(s, f) // up again, now square to the other two

	m: matrix[4, 4]f32
	m[0, 0] = s.x;  m[0, 1] = s.y;  m[0, 2] = s.z;  m[0, 3] = -linalg.dot(s, eye)
	m[1, 0] = u.x;  m[1, 1] = u.y;  m[1, 2] = u.z;  m[1, 3] = -linalg.dot(u, eye)
	m[2, 0] = -f.x; m[2, 1] = -f.y; m[2, 2] = -f.z; m[2, 3] =  linalg.dot(f, eye)
	m[3, 3] = 1

	return m
}
