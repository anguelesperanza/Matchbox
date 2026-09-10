# Lighting Rework -- Session Handover

Written 2026-09-09 at the end of P6, and updated 2026-09-10 at the end of P7b
-- see "Phase status" and "What is next", which are the two sections that go
stale. Written because the session doing this work outgrew its context. This is what a fresh session needs
to pick it up. It is not a summary of the work -- `lighting_rework.md` is that,
and it is current.

## Read these first, in this order

1. `CLAUDE.md` -- the house style, and binding. Note its **Scope** section is
   new (2026-09-09): Matchbox is a complete framework again, not a rendering
   and input layer. An audio API is due to merge in from separate work.
2. `lighting_plan.md` -- the owner's spec. The thing being built.
3. `lighting_rework.md` -- the implementation plan, and the live document. §7
   holds every decision the owner has made, §2/§2.1 the modularity contract,
   §8 the verification standard. **It is kept current** -- when a phase
   contradicted it, the plan was corrected rather than the contradiction
   ignored, so it can be trusted as a description of what is actually there.

## Where the work is

| Branch | What |
| --- | --- |
| `lighting-rework` | **The checkpoint.** Pushed to `origin`, P0 through P7b plus the scope change and `examples/lighting-lab`. This is the restore point. |
| `lighting-rework-p6` | Where HEAD currently sits -- the branch name is P6's but the work on it runs through P7b. Same commit as the checkpoint. |
| `lighting-rework-p0` … `-p5` | Each phase's own branch, stacked. Kept for history; nothing needs them. |

`main` is untouched and has none of this. Nothing has been merged and no pull
request has been opened -- the owner merges as soon as a PR appears, so do not
open one until the work is meant to land.

**The checkpoint discipline, which the owner asked for explicitly:** after each
phase is verified, fast-forward `lighting-rework` to that phase's tip and push
it. `git branch -f lighting-rework <commit>` then `git push origin
lighting-rework`. Do it as a branch pointer, never a checkout, so a running
agent's working tree is not disturbed.

## Running the gates

From the repository root. These are the numbers as of this handover:

```
odin check matchbox -no-entry-point          # must produce no output
odin test matchbox -define:ODIN_TEST_THREADS=1   # 240 tests, ~3.8s
```

Every example must build -- **27 of them have a `main.odin`**;
`examples/random-walk` is a pre-existing empty directory and the only skip:

```
for d in examples/*/; do n=$(basename "$d"); [ -f "$d/main.odin" ] || continue;
  odin build "$d" -out:"$TMPDIR/x_$n.exe" || echo "FAIL $n"; done
```

Shaders: `build_shaders.bat` from the repository root. **Run it through
PowerShell** -- `cmd.exe /c build_shaders.bat` from the Bash tool prints a
banner and silently does nothing. `dxc` is on PATH from the Vulkan SDK. Both
the `.spv` and the `.dxil` must be regenerated and committed for every shader
touched; CLAUDE.md calls one without the other a broken build for somebody.

`cheatsheet.md` is generated: `python tools/gen_cheatsheet.py`. Regenerate it
whenever a public procedure or its first doc-comment sentence changes.

**`python tools/check_shader_layout.py` after touching any shader.** It
preprocesses every one, computes each cbuffer's HLSL size from the expanded
declaration, and checks it against the `#assert(size_of(...))` lines in
`init.odin` -- plus the uniform-buffer limit, the sampler floor, and the
storage-buffer register sequence. It exists because two layout bugs got
through everything else: a cbuffer member the shader had and the Odin struct
did not (four phases old, CASCADED reading undefined memory), and a fifth
uniform buffer where SDL_GPU allows four (a startup crash). Neither is
visible to `odin check`, to `dxc`, or to a size assert on one side alone.

**Two things in the tree are not yours.** `improvements.md` has uncommitted
edits belonging to the owner, and `matchbox/stb/` is untracked but needed by
the build. Never `git add -A` from the repository root or inside `matchbox/` --
it sweeps `stb/` in. Add files by explicit path. (This happened once and had to
be amended out.)

## How the work has been run

Each phase is dispatched to a Sonnet agent with a long, specific brief: the
scope, the decisions already made, the gates, the verification standard, and
what to report. Then **its claims are verified independently before anything is
checkpointed.** That second half is not ceremony. Three examples of why:

- **P3 reported that SDL_GPU cannot render into a layer of a depth-stencil
  target**, and built six separate depth textures per cube caster on that
  basis, producing a 20-sampler fragment shader. The field exists; it is
  spelled `layer` rather than the colour target's `layer_or_depth_plane`. That
  shader would have failed on any device at Vulkan's guaranteed floor of 16 --
  which includes Android, a platform this framework targets. Caught by reading
  the binding, not the report. P3b fixed it.
- **P2d chose to load every glTF material as Blinn-Phong**, reasoning that the
  spec says the game picks the shading model. But that left the loader reading
  metallic, roughness, occlusion and emissive into a material where nothing
  read them -- the whole job inert. The owner reversed it (§7.6).
- **P5 flagged that its cluster depth reconstruction was perspective-only.**
  Checking whether that mattered showed `Camera3D_Projection.ORTHOGRAPHIC` is a
  supported mode, so an orthographic scene using `CLUSTERED` got silently wrong
  lighting. Fixed in-session.

The pattern: agents are good and their reports are honest, but they are written
from inside the work. Check the load-bearing claim against the code.

**Verification here is CPU-side, always.** There is no GPU in this environment
and no capture tooling. Nothing has been seen to render, at any point, across
the whole rework. Every phase's evidence is a CPU mirror of the shader maths
asserted against independently-derived numbers. Say so plainly rather than
implying more -- "I have not seen it render" is a sentence the owner has
accepted every time it was true.

Three anti-patterns that each cost real time here, and are worth stating in
every brief:

- **Do not assert on source text.** A test that greps a file breaks when a
  local is renamed and blames the wrong thing. P2a wrote six such tests; they
  were removed.
- **Do not copy an implementation's output into the expected value.** That
  asserts only that the code does what it does.
- **Do not spot-check where a sweep is possible.** P2c's white-furnace sweep
  found three separate bugs precisely because it swept roughness rather than
  testing one value; P5's cluster sweep caught a bug in its own test setup.
- **A test can pin a defect as firmly as a property.** P7c's SSAO kernel was a
  spiral -- a tap's angle around the normal and its distance from it both
  driven by the index, correlation 0.965 -- which printed the per-pixel noise
  function straight into the image. A test asserted exactly that shape
  ("lengths rise monotonically with index") and passed for two phases. Ask
  what a test would *rule out*, not only what it requires: a passing suite is
  not evidence the shape is right.

**Tell every agent to commit early and often.** P4's first attempt was killed
by a rate limit having written ~520 lines with zero commits, and a second agent
had to reconstruct it. P6 was killed the same way but had committed three times
and lost only one unfinished file.

## Phase status

P0 through P6 are complete, verified and checkpointed. What each established,
in one line, with the detail in `lighting_rework.md`:

- **P0** -- the seam. `Surface`, the BRDF and shadow contracts, `Material`,
  lights in a storage buffer, and lighting made explicit scene state rather
  than something emergent from list length.
- **P1** -- HDR. The 3D pass renders to `RGBA16_FLOAT` and a tonemap resolve
  encodes once, so no shading model owns a transfer function.
- **P2** -- four sub-phases: sRGB texture decode, the split BRDF contract
  (`sample_light` / `brdf_light` / `brdf_resolve`), four shading models, and
  the glTF material loader.
- **P3** (+ **P3b**) -- the shadow bias framework, an acne/peter-panning
  harness, PCSS, cascaded maps, cube shadows for point lights; then P3b
  collapsed 20 samplers to 8.
- **P4** -- area lights, hemisphere and probe ambient, IBL. **The BRDF contract
  absorbed area lights without being widened**, which §2.1 had flagged as the
  open question since P2.
- **P5** -- clustered forward with CPU-side light culling, and
  `Render_Pipeline_Kind`'s first real dispatcher.
- **P6** -- the deferred pipeline, which is what audited the whole design.
  `Surface` held, with exactly one hole: `blinn_phong` read the specular
  exponent off the bound material cbuffer, which is fine for forward and
  impossible for a deferred lighting pass. Fixed by widening `Surface`.
- **P7a** -- the post chain: bloom and colour grading, and the rule that
  decides what belongs in it (*a stage that needs a pass gets one; a stage
  that is a per-pixel function of one texel does not*). Its own tests found
  four bugs, three of them "an identity that is only nearly an identity".
  Section 7.8.
- **P7b** -- SSAO and volumetric light. The asymmetry the brief flagged was
  real and covered only half the phase: SSAO needs depth *before* shading and
  costs the forward family a depth prepass plus a deferred scene queue;
  volumetrics needs it *after* and is pipeline-agnostic for free. Section 7.9.
- **P7c** -- localized reflection probes, captured from the scene rather than
  from a sky, blended per fragment, all of them in one pair of texture arrays
  so four probes cost the sampler slots one does. Section 7.10.
- **`examples/lighting-lab`** -- a room built to make every module visible one
  key at a time, depending on no asset files at all. **The owner has run
  this**, which is the only frame this rework has ever produced; the three
  things that came back were all real and all are recorded in section 7.10.

## What is next

**P8** is 2D, and is now the whole of what remains of the plan -- see below.
P7 is finished: P7a the post chain, P7b SSAO and volumetrics, P7c the
reflection probes. Baked lightmaps and real-time GI stay recommended out of it
entirely, on the same grounds normal mapping left P2.

**Before it, run `examples/lighting-lab` again.** One session in it has
already produced three real findings (section 7.10) and it is the only frame
this rework has ever had rendered. Everything else here is CPU-side
arithmetic. An hour in that example is still worth more than the next phase. Its own top comment says what to look at and in what
order; the highest-value check is pressing **P**, since a picture that changes
between FORWARD, CLUSTERED and DEFERRED means the `Surface` seam is wrong
somewhere, and that is the gate P5 and P6 both had to leave unrun.

**P8** is 2D, and §7.3 settles what it means: normal-mapped sprites filling the
same `Surface` and running the same BRDFs, *and* 2D light volumes for the
stylised case. Note §3.7.1's rule -- sprites upload as `UNORM` today precisely
because the 2D pass has no resolve step, and P8 giving it one changes that
answer.

## Open items, deferred deliberately

Each is recorded where it belongs; none is forgotten.

- **Normal mapping** (§7.5) -- needs a tangent basis this package has none of.
  Widening `Vertex3D` touches every pipeline's vertex layout; deriving from
  screen-space derivatives is cheap but worse on low-poly geometry. Its own
  briefing, with the vertex-format question asked out loud.
- **`KHR_materials_pbrSpecularGlossiness`** -- not parsed. Archived extension,
  untyped `json.Value`, and the spec's own required `pbrMetallicRoughness`
  fallback is the designed path for a client like this. A warning now names the
  material when a file uses it. The owner knows the shader half
  (`PBR_SPECGLOSS`) already works and only the loader is missing.
- **`UNLIT` pays for the whole light loop** (§2.1) -- `sample_light` runs, with
  its shadow lookup, before dispatching into a model that discards all of it.
  Left alone because the fix is either a seam violation or a fifth touch point,
  for a cost nothing here can measure.
- **The scaling half of P5's gate** was never measured, and cannot be here.
  `examples/lighting-lab`'s N key is the pair of pictures it needs -- three
  lights against twenty-odd, switchable against the pipeline.
- **P7a and P7b's own deferred list** is in `lighting_rework.md` §7.8/§7.9:
  no Karis average in the bloom downsample, no bilateral SSAO blur, no
  half-resolution AO or volumetrics, no G-buffer normal path for `DEFERRED`,
  and only half of the volumetric absorption. Every one of them wants a frame
  to tune against.
- **Nothing has been seen to render.** The owner has checked
  `examples/lighting` by hand once, after P0. That is the only visual
  confirmation this rework has.

## Repo facts worth not rediscovering

- `MESH_FRAG_SAMPLER_COUNT` is **10** (`render.odin`) and `render_test.odin`
  pins it **under 16**, because Vulkan's guaranteed per-stage minimum for both
  `maxPerStageDescriptorSampledImages` and `maxPerStageDescriptorSamplers` is
  16 and Matchbox targets Android. `DEFERRED_LIGHTING_SAMPLER_COUNT` is 11 and
  pinned the same way. **If a design needs more than 16, that is a stop-and-ask,
  not a pin to raise.**
- Storage buffers continue the fragment stage's `t` register sequence *after*
  all sampled textures. Add a sampler and every storage buffer renumbers.
  `lighting_core.hlsli` documents it; P2d, P3b and P5 are the precedents.
- **Odin block comments nest.** A doc comment containing a path glob like
  `shaders/brdf/*.hlsli` opens a second comment that never closes, and the
  error surfaces at end-of-file, far from its cause. This cost real time in P6.
- `core:testing` has assertions and **no logging call at all** -- not `log`,
  not `logf`. Use `core:log`.
- Returning a slice of a compound literal from a procedure borrows that
  procedure's stack frame and Odin rejects it. Return a fixed-size array.
- The test suite's ~4 seconds is almost entirely P2c's white-furnace
  integration. That is bought, not waste.
- A ~900-byte leak warning from `set_lights` under `odin test` is known and
  benign -- the tests never call `cleanup`, which is what frees it.
- Stale background-task notifications arrive for agents that finished long ago,
  sometimes marked "killed". Check the actual git state rather than reacting.
- **A sampler count can be checked against the compiler rather than against
  arithmetic**, and `tools/check_shader_layout.py` now does it (plus the
  cbuffer sizes and the uniform-slot limit) -- run it after touching a shader.
  The pins in `render_test.odin`/`gbuffer_test.odin` only catch a *change*;
  that tool checks the invariant.
- **SDL_GPU allows four uniform buffers per shader stage.** A fifth is not a
  warning: `CreateGPUShader` fails and `create_builtin_shader` panics, so the
  program dies in `init` before drawing anything. Fragment slots here are
  material (b0), scene (b1), the two map-array shadow techniques' shared block
  (b2) and the reflection probes (b3), and that is all of them. Anything
  further wants a storage buffer, the way the light list already does.
- **A composite literal cannot go straight into a `for ... in` clause or an
  `if` condition** -- `for x in [?]f32{...}` and `if v != [3]f32{0,0,0}` are
  both syntax errors, since the `{` is read as the start of the block. Assign
  to a local first. Cost twenty minutes across P7a.
- **`core:fmt` reads `{` as a format directive**, so a test message written as
  `"got {%.2f, %.2f}"` comes back as `%!(MISSING CLOSE BRACE)` rather than the
  numbers you wanted to read. Use parentheses in failure messages.
