# The PICA200 vertex backend (3DS)

> **Hardware status (2026-11-23):** `mesh.mbs`'s generated program runs on a real New 3DS LL: rectangles, textured
> sprites, a 480x270 background, circles, lines, blended boxes and system-font text all draw (`gpu_test5`). It took
> one fix that no emulator showed, below in "Output registers are written whole". Other shaders and the other `.tev`
> stage shapes have only run in Azahar.

## Output registers are written whole (real hardware hangs otherwise)

**Rule:** every instruction that writes an output register (`mbs_out_*`) writes all four components, `.xyzw`. A
`vec2` or scalar output is built in a temporary first, the missing lanes 0 and `w` 1 (what an attribute loader fills
in for components it isn't given), and the temporary is moved to the output whole. `generate_vertex` in
`pica_stmt.odin` does this; `every_output_register_is_written_whole` in `pica_test.odin` checks `mesh.mbs` and
`hit_flash.mbs`, and fails on the old generator.

**Why:** on a real New 3DS LL the GPU **hangs** on the first draw whose vertex shader writes only part of an output
register: `mov mbs_out_texcoord0.xy, r1.xyzw` froze the console, with no error and the frame never finishing. Azahar
and Citra draw the same program correctly, so emulator runs can't catch it. Written whole (`mov outtc0, inuv`, as
devkitPro's textured examples do) the same draw runs.

**How it was found** (2026-11-23, bisected on hardware one feature per frame, each frame waiting at most 3 s for the
GPU and printing which step it was on):
1. `gpu_test`: clear and an empty camera pass were fine; the first real draw hung.
2. `gpu_test2`: one triangle with `C3D_DrawArrays` and nothing else (no index buffer, texture, depth, alpha test,
   blending or culling) still hung, so none of those were the cause.
3. `gpu_test3`: devkitPro's `simple_tri` shader drew, on its own layout and on Matchbox's three-attribute `Vertex`.
   Adding a `texcoord0` output written `.xy` hung.
4. `gpu_test4`: the same output written whole drew, and so did the engine's own `render_rectangle` and a textured
   sprite with the mesh shader patched that way; `.xy` alone hung again.
5. `gpu_test5`: mbsc's regenerated output, unpatched, ran the engine's 2D draws.

If the 3DS freezes on a draw again, suspect the generated shader first: compare it with a devkitPro example that is
known to run on hardware, changing one thing at a time.

`mbsc shader.mbs -target:3ds --emit-pica -o:name` writes `name.v.pica`, which `picasso` (devkitPro) turns into a `.shbin`.
`--emit-reflection` with `-target:3ds` writes the file the runtime reads. The fragment stage is not a program on this
hardware; it is the TexEnv plan (S6).

## What the output looks like

- Every procedure is inlined into `main`. A `for` with constant bounds is written out (at most 64 turns). A `return`
  must be the last thing a procedure does, or end both sides of a last `if`.
- A value takes one register per vector or scalar, one per matrix **row**, and one per element or field for arrays and
  structs. A vector lives in the lowest components (`[3]f32` in `.xyz`).
- picasso's operand rules are met by the generator: a uniform or constant is the first source of `add`, `mul`, `max`,
  `min`, `dp3`, `dp4` (sources are swapped, or the operand copied to a temporary, when needed); constants are never
  negated inside an instruction; two different inputs never meet in one instruction. `rcp`, `rsq`, `ex2`, `lg2` are
  written once per component. `mad` is not used.
- `if` is `cmp` + `ifc` (one comparison, or two joined with `&&` / `||`) or `ifu` for a `bool` uniform. A condition on
  loop counters is settled while writing.
- Uniforms: `.fvec name` (scalar or vector), `.fvec name[rows]` (matrix), `.fvec name[count]` (array). Struct fields
  are joined with `_` (`light_strength`), array-of-struct elements get their index (`lights_1_color`), engine fields are
  `<block>_<field>` (`frame_view_projection`, `render_tint`). `bool` uniforms are `.bool`. Only uniforms the shader reads
  are declared. A name that looks like a register (`v3`) gets `mbs_` in front.
- Outputs are `.out mbs_out_<tag> <tag>` for each `out:` field. Attributes arrive in `v0`, `v1`, ... in the order of the
  fields of the vertex input.
- The generator keeps to 16 temporaries, 512 instructions and 96 float registers (uniforms plus constants) and reports a
  problem otherwise.

## Runtime contract (reflection file)

```
mbs-reflection 1
target 3ds
attribute <attr> <type> <register>
uniform <name> <type> <registers>
bool <name>
```

The runtime finds each uniform by name with `shaderInstanceGetUniformLocation`. A matrix is uploaded one row per
register (`C3D_FVUnifMtx4x4` does that for a `C3D_Mtx`); a `[4]f32` with `C3D_FVUnifSet`; a bool with
`C3D_BoolUnifSet`.

## How it is checked

- `pica_test.odin` assembles every built-in's program, the shipped shaders, and feature shaders (loops, conditions,
  calls, assignment, struct/array uniforms, matrices) with the real picasso (found through `PICASSO`, `DEVKITPRO` or
  `C:/devkitPro`; skipped when absent).
- `pica_machine_test.odin` runs the generated assembly on a small model of the vertex unit, and `ir_eval_test.odin`
  evaluates the intermediate form directly; the two must agree on random inputs (mixed signs, positive only, exact
  halves, whole numbers).
- On Azahar a triangle drawn with a generated vertex shader (matrix from `C3D_Mtx`, a `[4]f32` tint, a `bool`
  uniform, the vertex colour output) came out the colour and place expected, both with the bool on and off.
- On a real New 3DS LL, `mesh.mbs`'s program runs the engine's 2D draws (2026-11-23, see "Output registers are
  written whole"). Emulators and hardware disagree on what the GPU accepts, so a generated change that alters how
  outputs or registers are written wants a hardware run, not only Azahar.

## The fragment stage: the `.tev` plan (S6)

`--emit-pica` also writes `name.tev`. The 3DS has no fragment program; the fragment shader is turned into TexEnv stages
(at most 6) plus an optional alpha test, and the runtime applies them with `C3D_TexEnv*` and `C3D_AlphaTest`.

```
mbs-tev 1
target 3ds

texture <unit> <name> texcoord <n>

stage <i> <FUNC> <source0> [source1] [source2] [constant uniform <name> | constant r g b a]

alphatest <FUNC> <ref | uniform name>
```

A source is `TEXTURE0..3`, `PRIMARY_COLOR`, `PREVIOUS` (the previous stage's result) or `CONSTANT`; a trailing `!` means
"one minus" (the ONE_MINUS operand). Example, the shipped `mesh.mbs`: `stage 0 MODULATE TEXTURE0 PRIMARY_COLOR` and
`alphatest GEQUAL uniform render_alpha_cutoff`.

Mapping: `*` MODULATE, `+` ADD, `-` SUBTRACT, `lerp(a, b, t)` INTERPOLATE (source0 = b, source1 = a, source2 = t),
`1.0 - x` the ONE_MINUS operand, `a * b + c` MULTIPLY_ADD, `(a + b) * c` ADD_MULTIPLY, `saturate(x)` is `x` (stages clamp).
Helper procedures are read through when they are straight-line. `if c.a < ref do discard()` becomes the alpha test that
keeps the pixels the condition does not discard (`<` GEQUAL, `<=` GREATER, `>` LEQUAL, `>=` LESS, `==` NOTEQUAL,
`!=` EQUAL); `ref` is a literal or an `f32` uniform. A sample's coordinate must be an unmodified `texcoord` output of the
vertex stage.

What it cannot do is reported as a problem: MBS-E3 (more than six stages, or two computed values meeting in one stage,
since only one can wait in PREVIOUS), MBS-E21 (two different constants in one stage), MBS-E12/MBS-E2 for shapes outside
the plan. These come from the backend as text without a source span yet. Stages work in 8-bit, clamped arithmetic, so
results can differ slightly from the PC's float output.

Checked by `tev_test.odin` (golden plan for `mesh.mbs`, each operation, fusion and chaining, helpers, alpha functions,
the errors). Run on Azahar once, with the stages applied by hand in a throwaway test app (no runtime reads `.tev` yet): the plan
`stage 0 MULTIPLY_ADD TEXTURE0 PRIMARY_COLOR CONSTANT` (generated by mbsc from `tex * color + bias`) with a texture
(0x80, 0x80, 0xFF), vertex colour (0.5, 1, 1, 1) and constant (0x20, 0x10, 0x40) drew exactly the expected
(0x60, 0x90, 0xFF) at alpha 1. With texture alpha 0x80 the result blended with the clear colour as citro3d's default
alpha blending predicts. An alpha test of GEQUAL 0x70 kept the triangle and GEQUAL 0x90 discarded it. Not covered:
the other functions (INTERPOLATE, ADD_MULTIPLY, the one-minus operands, PREVIOUS chaining across stages), several
textures, and any real 3DS. Note for the runtime: citro3d blends by default, so a draw that should be opaque must turn
blending off itself.

Not written yet: indexing a matrix, assigning a matrix row, boolean values (only as conditions), a matrix built from
vectors, early `return`.
