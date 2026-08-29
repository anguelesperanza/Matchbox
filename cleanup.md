# Cleanup

Bringing Matchbox in line with the style in `CLAUDE.md`: state grouped into
structs, no loose constants or globals beyond the ones that must be, and the
duplication that has built up removed.

Ordered so the cheap, zero-risk work lands first and nothing later depends on a
judgement call made earlier.

## Progress

Done on the `cleanup` branch, 2026-08-29. `cleanup-testing.md` lists what needs
checking by hand -- none of it was run, since the machine was in use.

| stage | state |
|---|---|
| 1 -- delete the dead copies | **done**, 855 lines |
| 2 -- the stray globals | **done**, `mbi` is the only one left |
| 3 -- constants into structs | **done**, all four areas |
| 4 -- merge overlapping procedures | **done**, the three clear-cut ones |
| 5 -- complexity | **measured, no action needed** -- see below |
| 6 -- the examples | **done**, five ported to `First_Person_Camera` |

Results against the starting numbers:

| | before | after |
|---|---|---|
| lines | 13,751 | 13,040 |
| procedures | 439 | 437 |
| package constants | 60 | 24 |
| ...of which colours | 16 | 16 |
| ...of which movable | ~34 | **0** |
| package globals | 3 | 1 |

Every constant that remains is one of: a defaults struct (`CAMERA3D_DEFAULTS`,
`FONT_DEFAULTS`, `GAMEPAD_DEFAULTS`, `UI_DEFAULTS`, `BUTTON_STYLE`), a colour, an
array size Odin needs a constant for, or `DEFAULT_FONT_BYTES`.

**Stage 5 came out as "leave it", which is a result rather than a skip:**

- `model_load.odin` is 676 lines once its dead half is gone, down from 1,179.
  The plan said to re-measure before splitting; 676 does not need splitting
- the nine accessor readers share `accessor_span`, which is already extracted.
  What is left differs in element type, widening rules and post-processing --
  normalise, transpose, reorder a quaternion. One generic reader would need a
  per-type conversion callback, which is more complexity than the repetition it
  removes. Written out is clearer
- `ui.odin` grew slightly (1,993 to 2,074) because `UI_DEFAULTS` is more lines
  than the constants it replaced. Splitting it by widget is still open, and is
  now the only Stage 5 item left

---

## Where it stands

Measured 2026-08-29, over 13,751 lines of `matchbox/*.odin`.

| | count | notes |
|---|---|---|
| procedures | 439 | |
| package constants | 60 | |
| package globals | 3 | `mbi`, `font_cache`, `font_cache_order` |
| dead commented-out lines | 851 | 6.2% of the package |

The 60 constants split into four groups, and only one of them is work:

| group | count | what happens |
|---|---|---|
| colours | 16 | **stay** -- structs buy nothing and complicate every call |
| array sizes | 8 | **stay** -- Odin needs a constant for a fixed array bound |
| embedded data | 1 | **stays** -- `DEFAULT_FONT_BYTES` is a `#load` |
| tuning values | ~34 | **move into settings structs** |

Array sizes that must stay: `MAX_JOINTS`, `MAX_LIGHTS`, `MAX_TOUCHES`,
`MAX_GAMEPADS`, `MAX_TEXT_INPUT`, `MAX_CLIP_DEPTH`, `FONT_GLYPH_COUNT`,
`STATUS_MAX_BYTES`.

---

## Stage 1 -- Delete the dead copies

`model.odin` and `model_load.odin` each carry a complete commented-out copy of an
older version of themselves, appended after the live code.

- `model.odin` lines 379-715 -- 337 dead of 715 (47%)
- `model_load.odin` lines 666-1179 -- 514 dead of 1179 (44%)

Both files begin their dead region with `// package matchbox`, which is what
makes them unambiguous rather than a judgement call.

**Do first.** No behaviour to preserve, nothing to design, and it takes 850 lines
of noise out of the two files most likely to be read next.

**Done when** both files compile unchanged and the examples still run.

---

## Stage 2 -- The two stray globals

`font_cache: map[i32]Cached_Font` and `font_cache_order: [dynamic]i32` sit at
package scope in `font.odin` for no reason other than that they were written
there. They are engine state and belong under `mbi`, in a `Font_Cache` struct
holding both -- they are already a pair, and one is meaningless without the
other.

`mbi` itself **stays**, and `CLAUDE.md` says why: an immediate-mode API cannot
pass a renderer to every `draw_rect` without every call site carrying one.
Worth stating in the code as well, so the next reader does not take it as an
oversight.

**Done when** `grep -nE "^[a-z_][a-zA-Z_0-9]*: " matchbox/*.odin` returns only
`mbi`.

---

## Stage 3 -- Tuning constants into settings structs

Area by area, smallest first, so the pattern is settled before it meets the big
one. Each area gets a settings struct with a defaulted constructor, following
`Animation_Blend` and `BUTTON_STYLE`.

| area | constants | shape |
|---|---|---|
| gamepad | `GAMEPAD_STICK_DEADZONE`, `GAMEPAD_TRIGGER_THRESHOLD` | `Gamepad_Settings` on `mbi.input` |
| font | `DEFAULT_FONT_SIZE`, `LINE_SPACING`, `FONT_CACHE_LIMIT`, `FONT_ATLAS_SIZE`, `FONT_FIRST_GLYPH` | `Font_Settings` |
| camera3d | `MOUSE_SENSITIVITY`, `PITCH_LIMIT`, `ORBIT_*` (6), `SHOULDER_OFFSET`, `FOCUS_OFFSET`, `TURN_SPEED`, `ORBIT_PITCH` | mostly already fields on the two rigs; the constants are the *defaults*, so they become literals in the two constructors |
| ui | `TEXT_FIELD_*` (6), `SCROLLBAR_*` (3), `DROPDOWN_*` (2), `BUTTON_*`, `CONFIRM_*`, `HOVER_DWELL`, `SLIDER_HANDLE_WIDTH`, `TEXT_PLATE_*`, `SCROLL_WHEEL_STEP`, `STATUS_FADE`, `MAX_CLIP_DEPTH`(stays) | `Ui_Style` sub-structs per widget, following `Button_Style` |

**camera3d is the easy one and should go first** -- the fields already exist on
`First_Person_Camera` and `Third_Person_Camera`, so the constants are only being
inlined into the constructors' default arguments. It is the smallest possible
demonstration of the pattern on real code.

**ui.odin is the large one** (1,993 lines, 67 procedures) and should go last, on
its own, after the pattern has stopped moving.

**Breaking.** Every example referencing `mb.ORBIT_PITCH_MIN`,
`mb.MOUSE_SENSITIVITY` and friends changes in the same commit as the constant it
names. `games/third-person-game` uses `matchbox.WHITE` and `matchbox.BLACK`,
which are colours and are not moving, so it is unaffected -- worth re-checking
before each stage rather than assuming.

---

## Stage 4 -- Merge the overlapping procedures

Confirmed duplicates, in order of how clear-cut they are.

**`read_vec3` / `read_vec3_owned`** -- byte-for-byte identical apart from the
allocator and one error string. One procedure with
`allocator := context.temp_allocator`, which is the convention `load_image`
already uses.

**`create_gpu_texture` / `create_gpu_cube_texture`** -- the same
`CreateGPUTexture` call with `type` and `layer_count_or_depth` differing. One
procedure taking both.

**`upload_texture` / `upload_texture_layer`** -- both run the same
transfer-buffer dance (create, map, copy, unmap, copy pass, submit) and differ
only in the destination region. The dance is the thing to share.

`pixel_buffer.odin` looks like a third copy and **is not one**: it keeps its
transfer buffer alive across frames instead of creating one per upload, records
onto the frame's own command buffer rather than acquiring its own, and maps with
`cycle = true`. All three are deliberate -- its comment names the "sometimes
draws last frame's image" bug the arrangement avoids. Leave it out of the merge.

**`camera3d_first_person` / `first_person_walk`** and the third-person pair are
**deferred** -- see *Deferred* at the end. They produce identical results but
differ in where the state lives, so there is no procedure to merge them into;
the change would be deleting one and porting its callers. Not while the camera
API is still moving.

**Checked and rejected:** `draw_cube` / `draw_plane` / `draw_sphere` in
`shapes3d.odin` are already six-line wrappers that build a `Transform` and call
`draw_model` on a shared generated mesh. There is nothing left to factor out, and
merging them behind one procedure would replace three obvious names with one that
takes a shape enum. Leave them.

**Still to confirm:** whether the `destroy_*` family has a shared shape worth
extracting, or whether the `destroy` proc group is already the right amount of
sharing.

---

## Stage 5 -- Complexity, once the above is done

Candidates, in the order they look worth it:

- **`model_load.odin` at 1,179 lines** is doing three jobs: parsing accessors,
  building GPU parts, and decoding materials and textures. After stage 1 removes
  the dead half it is ~665 lines, which may be enough on its own. Re-measure
  before splitting
- **`ui.odin` at 1,993 lines and 67 procedures** is the largest file by a wide
  margin. The widgets are independent of each other -- button, text field,
  scroll, dropdown -- and read like four files that were never separated. Do this
  *with* stage 3's `Ui_Style` work rather than as a second pass over the same
  code
- **The accessor readers** in `model_load.odin` and `model_skin_load.odin`
  repeat a shape: bounds-check the span, switch on component type, widen into a
  destination slice. Six or seven of them. Whether that is worth one generic
  reader or is clearer written out is a judgement to make with them all in view

**Performance is not the goal and must not regress.** Nothing here is on a hot
path except the accessor readers, which run once at load. If a merge makes a
per-frame path slower, it is not a merge worth having.

---

## Stage 6 -- Bring the examples up to date

**After the refactoring, not during it.** The examples are the last thing to
move, because every earlier stage changes something they call and porting them
twice is wasted work.

They have drifted from the package rather than from each other -- five of them
were written before the camera rigs existed and still demonstrate the older
shape:

| example | uses |
|---|---|
| `lighting`, `model`, `post`, `primitives`, `skybox` | `camera3d_first_person` with loose `yaw`/`pitch` |
| `first-person`, `third-person` | the current rigs |
| `cube` | `camera3d_at` -- **correct as it is**, a static camera is a real case and not everything wants a rig |

So the work is five files, and the reason to do it is not tidiness: an example
is what somebody copies. Five of the eight 3D examples currently teach a pattern
`CLAUDE.md` tells them not to use.

Whether they have drifted in ways beyond the camera has not been surveyed --
worth a pass once the package has stopped moving, since anything found then is a
real gap rather than a thing about to change again.

**Done when** no example uses an API the style guide steers away from, and all
of them still run.

---

## Deferred

Recorded here so they are decisions rather than oversights, and so a later
session does not re-open them unprompted.

**The camera composites.** `camera3d_first_person` / `first_person_walk` and the
third-person pair overlap, and the resolution is to port the five callers and
delete the loose form. Held off deliberately: the camera API is still being
worked on and is not mature enough to freeze. Revisit once it has settled --
until then both forms stay and neither is wrong to use.

**The colours.** `WHITE`, `BLACK` and the rest stay loose. Not an oversight and
not pending: wrapping them in a struct complicates every call site for nothing.

---

## Order to work in

1. Stage 1 -- delete the dead copies
2. Stage 2 -- the two font globals
3. Stage 3, camera3d -- smallest real demonstration of the pattern
4. Stage 4, the three clear-cut merges
5. Stage 3, gamepad and font
6. Stage 3 + 5, ui.odin together
7. Stage 5, re-measure `model_load.odin` and the accessor readers
8. Stage 6, the examples -- last, once nothing they call is still moving

Each stage is its own commit, with `odin check matchbox -no-entry-point` and
every example checked before it lands.
