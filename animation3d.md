# Layered animation for the 3D system

Written to be picked up cold, on a different machine, without the conversation
that produced it.

## The problem

`Animator` plays exactly one clip. It has a crossfade — `Animation_Blend` —
but that is a *transition between* two clips over a fifth of a second, not two
clips contributing to a pose at the same time. There is no way to say "these
joints come from that clip".

So a character who can reload while moving needs a clip per pair: reload×idle,
reload×walk, reload×run, reload×crouch. Add a second weapon and it doubles. Add
a third movement state and it grows again. The animator authors a matrix of
clips that are mostly the same motion glued to a different lower body.

What is wanted instead: a **base** clip driving the whole skeleton, and one or
more **layers** driving a named subset of it — the reload plays on the upper
body while whatever the legs are doing carries on underneath.

## Why this is a contained change

Two facts about the existing code make this much smaller than it sounds. Both
were checked before this was written:

**`sample_pose(model, playback, into: []Transform)` writes a complete pose into
an arbitrary buffer.** It copies the rest pose in and applies the clip's tracks
over it. It does not know or care whose buffer it is. So sampling a layer is
the function that already exists, pointed at different memory.

**`animator_resolve` reads only `pose.locals`.** It walks `skeleton.order` to
build `pose.globals`, then builds the skin palettes from those. It never looks
at the playback, the blend, or anything else. So *everything downstream of the
pose is already layer-agnostic* — the palettes, the shader, `node_matrix`,
weapon attachment. Layering only has to change what ends up in `locals` before
`animator_resolve` runs.

The insertion point is therefore one place: in `update_animator`, after the
base pose is in `pose.locals` and its crossfade has been mixed, before
`animator_resolve` is called.

---

## Step 0 — a prerequisite, and it is a real bug

**`play_animation` restarts the clip every single call.** `play_animation_index`
ends with an unconditional:

```odin
animator.clip    = index
animator.time    = 0
animator.looping = looping
animator.playing = true
```

Measured: an animator 0.4s into "Walk", asked for "Walk" again, is back at
`time = 0.00`. So a state machine calling `play_animation(&anim, model, "Walk")`
every frame — the obvious way to write one, and exactly what the 2D side's
`switch_animation` is *designed* to allow — freezes the character on the first
frame forever.

The blend logic four lines above already checks `animator.clip != index`, so the
same-clip case was recognised; it just never reached the time reset.

**Fix it before layering**, because layering makes state-machine-driven
animation more likely, not less. Give 3D the two verbs 2D has:

- `play_animation` becomes **idempotent** — asking for the clip already playing
  changes nothing but `looping`. Safe to call every frame.
- `replay_animation_3d` (name it to match whatever reads best beside the 2D
  `replay_animation`) restarts explicitly, which is how a one-shot is
  retriggered.

This mirrors `switch_animation` / `replay_animation` on the 2D side exactly, and
`refactor.md` already records that the two systems should teach each other
rather than diverge.

---

## Step 1 — masks

A mask says which nodes a layer owns. Per node, not per joint — the two index
spaces are different and confusing them is the classic skinning bug (see
`node_index`'s doc comment).

```odin
animation_mask_below :: proc(model: Model, root: u32, allocator := context.allocator) -> []bool
```

Every node at or below `root` in the hierarchy. A game builds one at load:

```odin
spine, ok := mb.node_index(model, "spine.002")
upper     := mb.animation_mask_below(model, spine)
```

**Build it in one pass using `skeleton.order`,** which is already sorted so a
parent always precedes its children — that is what it exists for. Mark `root`,
then walk `order` and set `mask[n] |= mask[parents[n]]`. O(nodes), no recursion,
no depth walk per node.

Worth offering alongside it: a mask built from a list of node names, for a rig
where the wanted set is not one clean subtree.

## Step 2 — layers

```odin
MAX_ANIMATION_LAYERS :: 2   // an array size, which CLAUDE.md sanctions

Animation_Layer :: struct {
    using playback: Animation_Playback,
    mask:   []bool,   // node_count, owned by the animator
    weight: f32,      // 0 is off, 1 fully overrides the masked joints
    active: bool,
}
```

`Animator` gains `layers: [MAX_ANIMATION_LAYERS]Animation_Layer`, and
`Animation_Pose` gains one scratch `[]Transform` per layer, allocated in
`create_animator` alongside `locals` and `from` and freed in `destroy_animator`.

**The mask is copied into the layer, not referenced.** `create_animator`
allocates each layer's `mask` at `node_count`, and `play_animation_layer` copies
the caller's mask in. The caller can then free its own. This is deliberate: a
borrowed mask outliving or predeceasing the animator is a lifetime hazard, and
this codebase has already been bitten once by a shared-by-reference animation
type (`Animation_Clip` shared by `animation_range`, where
`destroy_animated_sprite` double-frees). 80 bools per layer per character is not
worth a dangling read.

The composition, in `update_animator`, after the base and before the resolve:

```odin
for &layer, i in animator.layers {
    if !layer.active || layer.weight <= 0 do continue

    advance_playback(&layer.playback, model, delta_time)
    sample_pose(model, layer.playback, animator.pose.layer_locals[i])

    w := clamp(layer.weight, 0, 1)
    for n in 0 ..< len(animator.pose.locals) {
        if !layer.mask[n] do continue
        animator.pose.locals[n] = transform_mix(
            animator.pose.locals[n], animator.pose.layer_locals[i][n], w)
    }
}
```

`transform_mix` already exists and is what the crossfade uses, so a layer at
weight 0.5 blends the same way a transition does.

API:

```odin
play_animation_layer       :: proc(animator: ^Animator, model: Model, layer: int, name: string, mask: []bool, looping := true) -> bool
stop_animation_layer       :: proc(animator: ^Animator, layer: int)
set_animation_layer_weight :: proc(animator: ^Animator, layer: int, weight: f32)
```

Same rule as step 0: `play_animation_layer` must be **idempotent** for the clip
already playing on that layer, or it inherits the bug being fixed.

---

## Decisions to make deliberately

**Override only, additive later.** An override layer *replaces* the masked
joints; an additive layer adds its delta from some reference pose on top of what
is underneath. Reload is override. Recoil, lean and breathing are additive.
Additive needs a second decision — what the reference pose is, usually the
clip's own first frame or the rest pose — and does not need making yet. Build
override, and leave additive until something actually wants it.

**Weight is set by the game, not ramped internally — at first.** A reload layer
snapping to weight 1 will pop. The game can ramp it (`weight += dt / fade`) in
three lines. If every game ends up writing that, fold a `fade_duration` into the
layer the way `Animation_Blend` does for the base — but do not build it
speculatively. Note that `camera_follow` exists on the 2D side for exactly this
"I do not want to remember the maths" reason, so this may well end up wanted.

**Layers do not crossfade between their own clips initially.** Switching a
layer's clip snaps. The base has `Animation_Blend`; giving each layer one is
more state and more `from` buffers, and is only worth it if switching layer
clips mid-play turns out to be common. State this limitation in the doc comment
rather than leaving it to be discovered.

**`MAX_ANIMATION_LAYERS` of 2** covers the case that motivated this (one upper
body action over one base). Raise it if a real need appears; every layer costs a
`[]Transform` and a `[]bool` per animator, per character.

---

## What can be tested without any 3D assets

**Most of it.** This matters, because the machine with the assets may not be the
machine doing the work.

`Model`, `Skeleton`, `Model_Animation` and `Animation_Track` are plain structs.
A test can build a synthetic skeleton by hand — say five nodes, a root with two
chains — and a synthetic clip whose tracks move known nodes to known values, all
without a GPU, a file, or a window. `matchbox/sprite_cache_test.odin` and
`matchbox/animation_test.odin` already do this shape of thing with zero-valued
structs.

Testable headlessly, and worth having tests for:

- the mask covering exactly the subtree below a node, and nothing above it;
- a mask built from a root with no children being just that node;
- a layer at weight 1 overriding only its masked joints, with unmasked joints
  still holding the base clip's values;
- a layer at weight 0 changing nothing;
- a layer at weight 0.5 landing halfway, checked against `transform_mix`
  directly;
- an inactive layer costing nothing;
- `play_animation` no longer resetting `time` when asked for the clip already
  playing, and `replay` still doing so.

**What genuinely needs the Windows machine and real assets:** whether the mask
covers the bones a person would call "the upper body" on an actual rig, whether
a reload reads correctly over a run, and whether the weight ramp looks right.
Those are judgements about motion, not about arithmetic — the arithmetic can be
pinned down first.

---

## Steps

Same gate as the rest of the package: `odin check matchbox -no-entry-point`,
every example, `odin test matchbox`, and `python tools/gen_cheatsheet.py` when
the public API moves.

0. **Fix `play_animation`'s restart-on-every-call**, with a test. Small, and
   independent of everything below.
1. **Masks** — `animation_mask_below`, built off `skeleton.order`, with tests on
   a synthetic skeleton.
2. **Layers** — the struct, the allocation in `create_animator`/`destroy_animator`,
   the composition loop, the three procedures, with tests.
3. **An example**, once a real rig is available. None of the existing 3D
   examples has a skeleton with a sensible upper-body split, so this may want a
   new asset rather than a new example file.
4. **Validate on a real character** — the part that needs the assets and the eye.

## Progress

| step | state |
|---|---|
| 0 — the restart-on-every-call fix | **done** — `play_animation` and `play_animation_index` are idempotent for the clip already playing, changing only `looping`; `replay_animation_3d` added for an explicit restart. Tested: a clock that had advanced is unchanged by re-asking for the current clip, and `replay_animation_3d` puts it back to zero. |
| 1 — masks | **done** — `animation_mask_below`, one pass over `skeleton.order` exactly as planned above. `animation_mask_named` added alongside it, for a set that is not one clean subtree. Tested against the five-node synthetic skeleton: a subtree, a leaf, and a named set. |
| 2 — layers | **done** — `Animation_Layer`, `MAX_ANIMATION_LAYERS :: 2`, the scratch buffers in `create_animator`/`destroy_animator`, the composition loop in `update_animator`, and `play_animation_layer`/`stop_animation_layer`/`set_animation_layer_weight`. Tested: weight 1 overrides only the masked joints, weight 0 changes nothing, weight 0.5 lands on `transform_mix`'s own answer, an inactive layer never advances its clock, and a layer is idempotent the same way the base clip is. |
| 3 — an example | **done** — `examples/animation-layers`, third-person camera and primitive-shape scenery from `examples/third-person`, with a real skinned `Model`/`Animator` in place of the cube placeholder and `play_animation_layer` masking `Pistol_Reload` to `spine_02` and up. The character itself is gitignored (see `.gitignore`) rather than committed — see the note below. |
| 4 — validate on a real character | **done, against `games/third-person-game`** — a real VRoid rig (80 nodes, 13 skins) with `Pistol_Reload` and locomotion clips that are exactly the case this document opens with. See below. |

**One validation guard beyond the plan's pseudocode**: `play_animation_layer`
rejects a mask whose length does not match the skeleton's node count, rather
than letting `copy` silently truncate it. A mask built against the wrong model
would otherwise cover an arbitrary prefix of the real one's nodes without
saying so.

**Validated against a real character.** `games/third-person-game` (one
directory up from this repo) has a VRoid rig with a `spine_02` joint sitting
right where "upper body" should start -- above the pelvis and both thighs,
below both clavicles and the neck -- and a `Pistol_Reload` clip alongside its
six locomotion clips. `main.odin` there now has `update_reload_layer`: holding
R plays `Pistol_Reload` on `animation_mask_below(model, spine_02)` while
whatever locomotion state is on the base keeps running, with the weight
ramped over 0.2s rather than snapping.

Measured with a scratch harness (built, run, and deleted; not kept as part of
either repository) that ran two animators over the same second of
`Walk_Formal` -- one with the reload layer at weight 1, one without -- and
compared `thigh_l`'s pose between them: **position and rotation matched to
five decimal places**, confirming zero leakage from the layer into a masked-out
joint. `upperarm_r` and `hand_r` rotations diverged from a layer-free baseline
by 0.169 and 0.108 respectively (a same-clip diff was ~0.001, so this is
real movement, not float noise) -- the reload is visibly a different clip on
the arm than `Walk_Formal`'s own arm swing. `spine_02` itself barely moved
(0.0011): a reload is an arm-and-hand action on this rig, not a torso one,
which is a fact about the clip rather than a problem with the mask -- `spine_02`
was still confirmed inside the mask directly, and `thigh_l` outside it.

The game's `main.odin` needed three mechanical renames to build against
current `main` at all (`load_model`/`load_skybox_cubemap` returning `Error`
rather than `bool`, `create_third_person_camera`/`create_first_person_camera`,
`get_delta_time`) -- the vendored Matchbox clone there had been sitting well
behind this repository since before the `create_x`/`get_x` prefix pass, not
specifically behind this branch. Fixed alongside the pull to `animation-3d`.

**Not yet seen rendered.** The numbers above were read out of
`animator.pose.locals` programmatically, the way `is_animation_frame_passed`'s
own test suite works -- correct by measurement, but nobody has watched the
character's arm actually reload on screen while the legs keep walking. That
last, purely visual check is the only piece of step 4 still open.

## Related

- `refactor.md` — the standing decisions for this package, including the rule
  that the 2D and 3D animation systems mirror each other in vocabulary.
- `CLAUDE.md` — house style, notably **no callbacks** (a layer reports its state
  by being asked, never by calling back) and no new package-level constants
  beyond array sizes.
- The 2D animation work this follows, merged in PR #13. Its `switch_animation`
  (idempotent — safe to call every frame) and `replay_animation` (explicit
  restart) pair is the model for step 0, and `matchbox/animation.odin` is where
  to read how they behave.
- `games/third-person-game` (one directory up from this repo) — the actual
  game that step 4's validation ran against, and the real-world source of the
  "reload over a run" case this whole document opens with. Its `main.odin`
  has `update_reload_layer`, which is the smallest real caller of
  `play_animation_layer` that exists anywhere right now.
