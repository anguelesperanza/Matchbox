package matchbox

/*
	Animation -- 3D
	---------------
	Skeletal animation: a hierarchy of joints, a set of clips that move them,
	and the matrix palette a skinning vertex shader needs.

	`3d.md` listed this under "Not doing", with the note that the first game
	wanting a character to walk is what starts it. This is that.

	**The split is the same one the cameras use.** A `Model` holds what came out
	of the file and never changes: the skeleton's rest pose, its hierarchy, and
	the clips. An `Animator` holds one character's playback -- which clip, how
	far into it, and the matrices that follow -- and a game makes one per
	character. Two goblins share the `Model` and have an `Animator` each, which
	is the same reason `draw_model` takes a `Transform` rather than storing one.

	The names here are `Model_`-prefixed or `_3d`-flavoured because 2D sprite
	animation already owns the plain ones: `AnimationClip`, `update_animation`
	and `load_animation` in `animation.odin` are the sprite ones and are
	unrelated to any of this.
*/

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"

// -----------------------------------------------------------------------
// What comes out of the file
// -----------------------------------------------------------------------

// Which part of a joint's transform a track drives. glTF's fourth path,
// `weights`, drives morph targets, which Matchbox skips at parse (see the
// MATCHBOX PATCH in gltf2/gltf.odin) and so never reaches here.
Animation_Path :: enum {
	TRANSLATION,
	ROTATION,
	SCALE,
}

/*
	How a track gets from one keyframe to the next.

	All three of glTF's, because a file picks per sampler rather than per file
	and mixes them freely -- the VRoid walk this was written against is 45 STEP
	channels and 22 LINEAR in the same clip.
*/
Animation_Interpolation :: enum {
	LINEAR,
	STEP,
	CUBIC,
}

/*
	One node's worth of one channel: the times, and the values at them.

	Rotations live in `quats` and everything else in `vectors`, rather than one
	array of four floats used four ways. A rotation is interpolated by slerp and
	a translation by a straight lerp, so the two were never going to share code,
	and keeping them apart means the sampler cannot pick the wrong one.

	Under `.CUBIC` there are three values per keyframe -- in-tangent, the value,
	out-tangent -- so the arrays are three times as long as `times`, and the
	sampler indexes accordingly.
*/
Animation_Track :: struct {
	node:          u32,
	path:          Animation_Path,
	interpolation: Animation_Interpolation,

	times:   []f32,
	vectors: [][3]f32,
	quats:   []quaternion128,
}

// One clip: everything that moves, and how long it runs.
Model_Animation :: struct {
	name:     string,
	duration: f32,
	tracks:   []Animation_Track,
}

/*
	One skin: which nodes are its joints, and the matrix that takes each joint
	back to the pose the mesh was modelled in.

	`joints` is an index into the skeleton's nodes, and the *position in this
	array* is what a vertex's `JOINTS_0` refers to. The two are different
	numbers and confusing them is the classic skinning bug -- a character folded
	inside out, which is what you get by indexing the palette with a node index.
*/
Model_Skin :: struct {
	joints:       []u32,
	inverse_bind: []matrix[4, 4]f32,
}

/*
	The node hierarchy a model's animation moves.

	`rest` is the transform each node has in the file before any clip touches
	it, and is what an animator starts every frame from -- a clip that drives
	only the arms leaves the legs at rest rather than at the origin.

	`order` is the nodes sorted so a parent always comes before its children.
	glTF does not promise that, and computing a global transform needs it: the
	parent's answer has to be finished before the child's begins.
*/
Skeleton :: struct {
	parents: []i32, // -1 for a root
	rest:    []Transform,
	order:   []u32,
	skins:   []Model_Skin,
}

// Whether a model has a skeleton at all. A cube does not.
model_is_skinned :: proc(model: Model) -> bool {
	return len(model.skeleton.rest) > 0 && len(model.skeleton.skins) > 0
}

// -----------------------------------------------------------------------
// One character's playback
// -----------------------------------------------------------------------

/*
	Where one character is in one clip, and the matrices that come out of it.

	`clip` indexes `model.animations` and is -1 when nothing is playing, which
	is what `create_animator` starts at: a character stands in its bind pose
	until the game asks for something.

	The three arrays are working space, sized once. `locals` is this frame's
	pose before the hierarchy is applied, `globals` after, and `palettes` is
	what the shader reads -- one per part, because a skinned part's palette
	depends on the node the mesh hangs off as well as on the skin.
*/
Animator :: struct {
	clip:    int,
	time:    f32,
	speed:   f32,
	looping: bool,
	playing: bool,

	locals:   []Transform,
	globals:  []matrix[4, 4]f32,
	palettes: [][]matrix[4, 4]f32,
}

/*
	An animator for `model`, with nothing playing.

	Allocates, so it is paired with `destroy` -- and it is per character rather
	than per model, which is the whole point: one `Model` on the GPU, an
	`Animator` for each thing wearing it.

	A model with no skeleton gets a zeroed animator rather than an error. That
	makes `create_animator` safe to call on whatever `load_model` returned, and
	`update_animator` on the result does nothing.
*/
create_animator :: proc(model: Model) -> Animator {
	if !model_is_skinned(model) {
		log.info("model has no skeleton; animator will do nothing")
		return Animator{clip = -1, speed = 1, looping = true}
	}

	node_count := len(model.skeleton.rest)

	animator := Animator{
		clip     = -1,
		speed    = 1,
		looping  = true,
		locals   = make([]Transform, node_count),
		globals  = make([]matrix[4, 4]f32, node_count),
		palettes = make([][]matrix[4, 4]f32, len(model.parts)),
	}

	for part, i in model.parts {
		if part.skin < 0 || part.skin >= len(model.skeleton.skins) do continue
		animator.palettes[i] = make([]matrix[4, 4]f32, len(model.skeleton.skins[part.skin].joints))
	}

	// The bind pose, so a character drawn before its first `update_animator`
	// is a character rather than a heap of triangles at the origin.
	copy(animator.locals, model.skeleton.rest)
	animator_resolve(&animator, model)

	return animator
}

destroy_animator :: proc(animator: ^Animator) {
	for palette in animator.palettes do delete(palette)
	delete(animator.palettes)
	delete(animator.globals)
	delete(animator.locals)

	animator^ = Animator{clip = -1, speed = 1, looping = true}
}

// The index of a clip by name, for a game that would rather write "Walk" than
// remember which number it came out as.
animation_index :: proc(model: Model, name: string) -> (index: int, found: bool) {
	for clip, i in model.animations {
		if clip.name == name do return i, true
	}
	return -1, false
}

/*
	What the clips in a model are called, in the order `play_animation_index`
	numbers them.

	For building something out of them -- a menu, a debug list, a test that
	plays each in turn. To *see* them while working out what an export
	contains, `print_animations` is the one to reach for.

	The slice is temp-allocated and lasts until the next `free_all` on the temp
	allocator, which for a game is the end of the frame. The strings inside it
	are the model's own and live as long as the model does, so keeping one past
	the frame is fine and keeping the slice is not.
*/
animation_names :: proc(model: Model, allocator := context.temp_allocator) -> []string {
	names := make([]string, len(model.animations), allocator)
	for clip, i in model.animations do names[i] = clip.name
	return names
}

/*
	Prints what a model's skeleton and clips are, to stdout.

	A working tool rather than something to ship: exporters name clips whatever
	they feel like, and the alternative to this is guessing at
	`play_animation("Walk")` and reading the error when it misses.

	Reports the skeleton first, because "no animations" and "no skeleton at all"
	are different problems with the same symptom -- the second one usually means
	the mesh was exported without its armature.
*/
print_animations :: proc(model: Model) {
	if !model_is_skinned(model) {
		fmt.println("model has no skeleton: nothing here can be animated")

		// A file can carry clips with no skin to drive -- they would move nodes
		// that no vertex is weighted to. Saying so is more use than silence,
		// because it means the armature was exported and the weights were not.
		if len(model.animations) > 0 {
			fmt.printfln("  (it does carry %v animation(s), with nothing skinned for them to move)",
				len(model.animations))
		}
		return
	}

	joints := 0
	for skin in model.skeleton.skins do joints = max(joints, len(skin.joints))

	fmt.printfln("model: %v nodes, %v skin(s), %v joints in the largest, %v part(s)",
		len(model.skeleton.rest), len(model.skeleton.skins), joints, len(model.parts))

	if len(model.animations) == 0 {
		fmt.println("no animations: the file has a skeleton but no clips to move it")
		return
	}

	fmt.printfln("%v animation(s):", len(model.animations))

	for clip, i in model.animations {
		// glTF lets an animation go unnamed, and Matchbox keeps the empty
		// string rather than inventing one. `play_animation` cannot find a clip
		// with no name, so the index is the only way in and the line says so.
		name := clip.name if clip.name != "" else "(unnamed -- use play_animation_index)"

		fmt.printfln("  [%v] %-32s %6.2fs  %v tracks", i, name, clip.duration, len(clip.tracks))
	}
}

/*
	Starts a clip by name, from the beginning.

	Returns false and leaves the animator alone if the model has no such clip,
	which is a typo or a re-export rather than something to stop the game for.
	The names a file actually carries are in `model.animations[i].name`.
*/
play_animation :: proc(animator: ^Animator, model: Model, name: string, looping: bool = true) -> bool {
	index, found := animation_index(model, name)
	if !found {
		log.errorf("model has no animation named %q", name)
		return false
	}

	play_animation_index(animator, model, index, looping)
	return true
}

// The same by index, for a game that resolved the name once and kept it.
play_animation_index :: proc(animator: ^Animator, model: Model, index: int, looping: bool = true) {
	if index < 0 || index >= len(model.animations) do return

	animator.clip    = index
	animator.time    = 0
	animator.looping = looping
	animator.playing = true
}

// Stops where it is. The pose stays put, which is what a paused character
// should look like; `play_animation` again to restart from the top.
stop_animation :: proc(animator: ^Animator) {
	animator.playing = false
}

/*
	Advances the clip and works out this frame's matrices.

	Call it once per character per frame, before drawing. `speed` scales the
	advance, so 0.5 is half speed and 2 is double; a negative one runs the clip
	backwards, which wrapping handles.

	A non-looping clip stops on its last frame and clears `playing`, which is
	what a game watches to know a one-shot has finished.
*/
update_animator :: proc(animator: ^Animator, model: Model, delta_time: f32) {
	if !model_is_skinned(model) do return
	if len(animator.locals) != len(model.skeleton.rest) do return

	if animator.playing && animator.clip >= 0 && animator.clip < len(model.animations) {
		clip := model.animations[animator.clip]

		animator.time += delta_time * animator.speed

		if animator.looping {
			// `mod` rather than a subtract, so a long stall or a big speed does
			// not leave the time several clips past the end.
			if clip.duration > 0 {
				animator.time = math.mod(animator.time, clip.duration)
				if animator.time < 0 do animator.time += clip.duration
			}
		} else if animator.time >= clip.duration {
			animator.time   = clip.duration
			animator.playing = false
		} else if animator.time < 0 {
			animator.time   = 0
			animator.playing = false
		}

		// From the rest pose every frame, not from last frame's. A clip drives
		// some joints and not others, and the ones it leaves alone belong where
		// the file put them -- accumulating instead would let them drift.
		copy(animator.locals, model.skeleton.rest)

		for track in clip.tracks {
			if int(track.node) >= len(animator.locals) do continue
			sample_track(track, animator.time, &animator.locals[track.node])
		}
	}

	animator_resolve(animator, model)
}

/*
	Local transforms to global ones, and global ones to matrix palettes.

	The palette entry for a joint is

		inverse(mesh node's global) * joint's global * joint's inverse bind

	which is glTF's formula in full. The first factor is the identity in most
	files -- a skinned mesh usually hangs off an untransformed node -- but not
	in all of them, and one matrix inverse per part per frame is not worth
	skipping to find out the hard way which kind of file you have.
*/
@(private)
animator_resolve :: proc(animator: ^Animator, model: Model) {
	skeleton := model.skeleton

	// Parents before children, which is what `order` is for.
	for node in skeleton.order {
		local  := transform_matrix(animator.locals[node])
		parent := skeleton.parents[node]

		if parent < 0 {
			animator.globals[node] = local
		} else {
			animator.globals[node] = animator.globals[parent] * local
		}
	}

	for part, i in model.parts {
		if part.skin < 0 || part.skin >= len(skeleton.skins) do continue
		if len(animator.palettes[i]) == 0 do continue

		skin := skeleton.skins[part.skin]

		mesh_inverse := linalg.MATRIX4F32_IDENTITY
		if int(part.node) < len(animator.globals) {
			mesh_inverse = linalg.inverse(animator.globals[part.node])
		}

		for joint, j in skin.joints {
			if int(joint) >= len(animator.globals) do continue
			animator.palettes[i][j] = mesh_inverse * animator.globals[joint] * skin.inverse_bind[j]
		}
	}
}

// -----------------------------------------------------------------------
// Sampling one track
// -----------------------------------------------------------------------

/*
	The keyframe at or before `time`, and how far past it we are.

	Returns the index of the left keyframe and a 0..1 blend to the one after.
	A time before the first key or after the last clamps to that key, which is
	what glTF asks for -- a clip does not extrapolate off either end.

	Linear search from the start would be O(keys) per track per frame, which for
	sixty-six tracks of a walk cycle is the sort of thing that quietly costs a
	millisecond; this bisects instead.
*/
@(private)
track_frame :: proc(times: []f32, time: f32) -> (index: int, blend: f32) {
	if len(times) == 0 do return 0, 0
	if len(times) == 1 do return 0, 0

	if time <= times[0]           do return 0, 0
	if time >= times[len(times) - 1] do return len(times) - 1, 0

	low, high := 0, len(times) - 1
	for high - low > 1 {
		mid := (low + high) / 2
		if times[mid] <= time {
			low = mid
		} else {
			high = mid
		}
	}

	span := times[high] - times[low]
	if span <= 0 do return low, 0

	return low, (time - times[low]) / span
}

// Hermite, which is what glTF's CUBICSPLINE is. `span` scales the tangents
// because they are given per second and the basis wants them per span.
@(private)
hermite :: proc(v0, out_tangent, v1, in_tangent: [3]f32, t, span: f32) -> [3]f32 {
	t2 := t * t
	t3 := t2 * t

	return (2 * t3 - 3 * t2 + 1) * v0 +
	       (t3 - 2 * t2 + t) * span * out_tangent +
	       (-2 * t3 + 3 * t2) * v1 +
	       (t3 - t2) * span * in_tangent
}

@(private)
sample_track :: proc(track: Animation_Track, time: f32, into: ^Transform) {
	if len(track.times) == 0 do return

	index, blend := track_frame(track.times, time)
	next         := min(index + 1, len(track.times) - 1)

	switch track.path {
	case .ROTATION:
		if len(track.quats) == 0 do return

		switch track.interpolation {
		case .STEP:
			into.rotation = track.quats[quat_at(track, index)]

		case .CUBIC:
			// The value elements either side, interpolated as a rotation. The
			// tangents are dropped: a cubic spline through quaternions is not
			// the same shape as one through their components, and slerping the
			// endpoints is both cheap and never wrong-looking. No exporter this
			// was tested against writes cubic rotations.
			a := track.quats[index * 3 + 1]
			b := track.quats[next * 3 + 1]
			into.rotation = linalg.quaternion_slerp_f32(a, b, blend)

		case .LINEAR:
			fallthrough
		case:
			a := track.quats[index]
			b := track.quats[next]
			into.rotation = linalg.quaternion_slerp_f32(a, b, blend)
		}

	case .TRANSLATION, .SCALE:
		if len(track.vectors) == 0 do return

		value: [3]f32

		switch track.interpolation {
		case .STEP:
			value = track.vectors[index]

		case .CUBIC:
			span := track.times[next] - track.times[index]
			value = hermite(
				track.vectors[index * 3 + 1], // value at the left key
				track.vectors[index * 3 + 2], // its out-tangent
				track.vectors[next * 3 + 1],  // value at the right key
				track.vectors[next * 3 + 0],  // its in-tangent
				blend, span,
			)

		case .LINEAR:
			fallthrough
		case:
			value = linalg.lerp(track.vectors[index], track.vectors[next], blend)
		}

		if track.path == .TRANSLATION {
			into.position = value
		} else {
			into.scale = value
		}
	}
}

// Cubic rotation tracks store three quaternions per key; every other kind
// stores one. Kept here so the STEP case reads the same either way.
@(private)
quat_at :: proc(track: Animation_Track, index: int) -> int {
	return index * 3 + 1 if track.interpolation == .CUBIC else index
}
