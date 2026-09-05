# Finishing the 2D animation system

## Why

A fighting game built on Matchbox (`games/farlite-test`) is hand-writing an
animation sequencer inside its own state machine, and the seams show. Three
things in that file are evidence rather than opinion:

- **`is_anim_playing` is written in four places and never read.** The fossil of
  reaching for a concept the API does not have.
- **`player.playing` is forced to `false` on key release.** Walk and run loop,
  so `playing` is always true for them, so the "have I finished" check can
  never fire on its own. The library's flag is being corrupted to fake a
  signal it cannot give.
- **Three enums -- `Jump_Phase`, `Guard_Phase`, `Crouch_Phase` -- exist only to
  sequence clips.** `jump_begin → jump_up → jump_rise` is a sequence expressed
  as an enum plus a pile of `if !playing { phase = next }`. That is not game
  logic wearing a costume; it is animation plumbing the library should own.

Plus the smaller ones: `frames_into_clip := current_frame - clip.frame_start`
is hand-rolled progress, and `stages[i].frame_count > 0` is a validity sentinel
because a `[15]Animation_Clip` has holes.

**The state machine itself is not the problem.** A fighting game needs one, and
its combo rules and cancel policy are genuinely the game's business. The
problem is that it is doing a second job -- sequencing clips -- that belongs
here.

## Settled before starting

| question | answer |
|---|---|
| the multi-frame advance fix | **done here**, as part of step 1 -- if the other session's fix lands too, the merge is the same change twice and resolves trivially |
| `MAX_ANIMATION_QUEUE` | **4** -- one spare over the deepest chain in the game today, ~260 bytes a sprite |
| where the work lands | **branch `animation`**, PR when done, as the refactor did |
| `queue_animation`'s `looping` | **no default** -- the caller states it. `switch_animation` defaults it to `true` and a queued clip usually wants `false`, so either default is inconsistent with something and both fail silently |
| `switch_animation` and the queue | **clears it** -- a hurt animation interrupting a jump must not resume the chain afterwards |
| `is_animation_in_window` bounds | **inclusive both ends**, matching `animation_range` |
| `get_animation_progress` | includes the accumulator fraction, so it moves smoothly rather than in steps; reads 1.0 on a finished one-shot |
| a full queue | drops the new entry and logs, rather than silently overwriting |

**A naming correction to this document's first draft.** It proposed
`did_animation_pass_frame`, which returns a `bool` and so breaks the `is_` rule
in `CLAUDE.md`. The precedent settles it without bending anything:
`is_key_pressed` already means "went down *this frame*", so a this-frame
question is squarely `is_`. The procedure is **`is_animation_frame_passed`**.

## Scope

Two features, both in `matchbox/animation.odin`, plus one gap to close.

**Neither of these is an event system**, and the distinction decides where they
live. An event bus -- publish/subscribe, listeners, lifetimes -- is a separate
package's job and is not what this problem needs. What is wanted is *data
attached to a clip* and *a question asked on the frame it matters*, which is
animation's own business and has no bus in it.

Everything here is **polled, never delivered**. See the no-callbacks rule in
`CLAUDE.md`.

---

## 1. Frame queries

Replaces arithmetic the game currently does by hand.

```odin
get_animation_frame    :: proc(sprite: Animated_Sprite) -> i32   // 0-based within the clip
get_animation_progress :: proc(sprite: Animated_Sprite) -> f32   // 0..1 through the clip
is_animation_in_window :: proc(sprite: Animated_Sprite, first, last: i32) -> bool
is_animation_frame_passed :: proc(sprite: Animated_Sprite, frame: i32) -> bool
```

The first three are stateless reads of `current_frame` and `accumulator`.
`get_animation_frame` alone deletes the `- clip.frame_start` subtraction from
every call site, and `is_animation_in_window` is the cancel-window test the
game writes as `frames_into_clip >= frame_count - cancel_window`.

**`is_animation_frame_passed` is the one with a subtlety**, and it is worth
getting right rather than discovering later. Once `update_animation` advances
*more than one frame per call* -- which is the fix for the frame-rate bug, and
may already be in flight elsewhere -- a single update can cross frames 3, 4 and
5 at once. A discrete marker on frame 4 must still fire, so a check shaped like
"is `current_frame` 4" or even "did `current_frame` change to 4" **silently
misses it at low frame rates**, which is the worst possible failure for a
footstep or a hitbox.

So the sprite records the span it crossed, not just where it landed:

```odin
Animated_Sprite gains:
    previous_frame: i32   // where the last update started
    stepped:        i32   // frames advanced during the last update, 0 if none
```

`is_animation_frame_passed` then answers over the span, wrapping with the clip:
`stepped == 0` is false, `stepped >= frame_count` is true (the update crossed
the whole clip), and otherwise it walks the span. Two `i32` per sprite.

### Named markers: deliberately not yet

`is_animation_frame_passed(&s, 4)` is a magic number where
`animation_event(&s, "hit_active")` would read better, and per-clip marker data
is a real thing a fighting game wants. It is **not** in this pass, for one
concrete reason: markers would be an owned slice on `Animation_Clip`, and
`Animation_Clip` is copied by value into every sprite *and* shared by
`animation_range`, which already has an ownership hazard --
`destroy_animated_sprite` frees the clip unconditionally, so two sprites cut
from one sheet double-release. Adding an owned allocation to that type
compounds a bug that is already there.

Do the numeric queries first, use them, and add names later if the magic
numbers actually hurt -- by which point the ownership question will have been
settled on its own merits rather than under pressure.

---

## 2. Clip sequencing

The bigger win for the game's codebase.

```odin
MAX_ANIMATION_QUEUE :: 4   // an array size, which CLAUDE.md sanctions

queue_animation :: proc(sprite: ^Animated_Sprite, clip: Animation_Clip, looping: bool)
clear_animation_queue :: proc(sprite: ^Animated_Sprite)
```

When a non-looping clip finishes and the queue is not empty, `update_animation`
pops the front and seats it -- same path `switch_animation` uses, so a queued
clip starts exactly as a switched one does.

The jump becomes three lines of data instead of an enum and four transitions:

```odin
mb.switch_animation(player, anim.jump_begin, looping = false)
mb.queue_animation(player, anim.jump_up)
mb.queue_animation(player, anim.jump_rise, looping = true)
```

`jump_fall` and `jump_land` stay in the game's state machine, correctly -- they
are driven by physics and input, not by the previous clip ending.

**A queue on the sprite rather than a `next` pointer on the clip.** The
alternative -- `Animation_Clip.next: ^Animation_Clip` -- reads better at the
definition site and was rejected: it puts a pointer into game-owned memory
inside a type that is copied by value and shared by `animation_range`, so a
clip outliving its `next` is a dangling read rather than a mistake, and every
range view would silently inherit the chain. The queue costs about 260 bytes
per sprite at depth 4 and has no lifetime question in it.

---

## 3. The restart gap

There is currently **no public way to replay a finished one-shot on the same
clip.** `switch_animation` detects the same clip and returns early -- which is
what makes it safe to call every frame from a state machine -- and
`seat_first_frame` is `@(private)`. A game retriggering the same attack has
nowhere to go.

```odin
replay_animation :: proc(sprite: ^Animated_Sprite)
```

One line over `seat_first_frame`. Keeps `switch_animation` idempotent, which is
the property the game depends on, and adds the verb it is missing.

---

## What this removes from `farlite-test`

Worth stating so the payoff is checkable rather than asserted:

| now | after |
|---|---|
| `Jump_Phase` BEGIN/UP/RISE + transitions | `queue_animation` ×2 |
| `Crouch_Phase` ENTER/HELD | `queue_animation` |
| `frames_into_clip` arithmetic | `get_animation_frame` |
| the cancel-window comparison | `is_animation_in_window` |
| no way to retrigger a combo stage | `replay_animation` |
| `is_anim_playing` (dead) | deleted |

**One thing this does not fix**, and the game should stop doing regardless:
forcing `player.playing = false` on key release. That is the game asking "has
this *state* ended", not "has this *clip* ended", and the answer is its own --
on key release it should set `state = .IDLE` directly rather than corrupting a
flag to make an unrelated check fire.

---

## Progress

| step | state |
|---|---|
| 1 -- the clock fix and the frame queries | **done**, `03e3eb5` -- 340 procedures, 27 tests |
| 2 -- `replay_animation` and the queue | next, together: both go through `seat_first_frame` |
| 3 -- an example | not started |

**Step 1 took the fix as arithmetic rather than a loop**, which was a
deliberate deviation and the better answer. `steps := i32(accumulator /
seconds_per_frame)` gives identical catch-up in O(1), where a loop leaves a
hang reachable from a large `delta_time` -- and `update_animation` takes that
as an argument, so nothing guarantees `poll_events` clamped it first.
`advance_playback` already works this way on the skeletal side.

`seconds_per_frame <= 0` **freezes the clip** rather than stepping once a call.
It is the zero value of `Animation_Clip`, so it is the state a hand-built clip
arrives in, and stepping once a call would run it at whatever rate the game
renders at -- silent, plausible, and the same class of bug as the one being
fixed. Standing still is what sends somebody to look at the clip data.

Two behaviours confirmed by hand afterwards, because both would break
`farlite-test` silently if wrong:

- A frame crossed **in the middle** of a multi-frame step reports as passed --
  a 0.35s update over a 0.1s clip crosses 1, 2 and 3, and all three answer
  true while 0 and 4 answer false. The starting frame is not "entered", which
  is the distinction a naive equality check gets wrong.
- A one-shot landing **exactly** on its last frame keeps `playing = true`, and
  only the step that would go past clears it, reporting `stepped = 0`. That is
  the original semantics preserved: the last frame gets its full duration, and
  every `if !playing` in a game keeps meaning what it meant.

## Steps

Same gate as the refactor: `odin check matchbox -no-entry-point`, all 24
examples, `odin test matchbox`, and `python tools/gen_cheatsheet.py` when the
public API moves.

1. **Frame queries.** Four procedures, two new fields, tests for the span
   arithmetic including the wrap and the whole-clip-crossed case. Land after
   the multi-frame advance fix, or with it -- `is_animation_frame_passed` is
   only meaningfully testable once an update can cross more than one frame.
2. **`replay_animation`.** Smallest of the three; unblocks the combo retrigger
   immediately.
3. **Clip sequencing.** The queue, the pop in `update_animation`, and tests
   for a finished non-looping clip pulling the next one.
4. **An example.** None of the 24 shows sequencing or frame queries; the
   nearest is `sprite-frames`. Either extend it or add one.

## After this

The 3D side, where the real gap is **layered animation with bone masking** --
playing a reload on the upper body while a run plays on the lower. `Animator`
holds exactly one playback plus one crossfade source, so today a game needs a
clip per (movement × action) pair, which does not scale past a couple of
weapons. `sample_pose` already writes into an arbitrary buffer, so the
composition end is well placed for it; the design work is masks and layer
order. Its own plan, once this lands.
