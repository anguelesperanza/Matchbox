# Built-ins and limits by target (draft for S0)

> **`shader_language.md` part 2 is the authority for built-in names and marks.** This file keeps the measurements and
> the reasoning behind them. Where the two differ (for example `frac` here, `fract` there), part 2 wins.

Sources: HLSL intrinsics (Microsoft Learn), the Cg standard library, the picasso manual, 3dbrew's
shader instruction set, and the o3dx `c3d` bindings, **then checked by running the compilers**:
`tools/mbsc_probe.odin` compiles one tiny shader per built-in with d3dcompiler (PC), `psp2cgc.exe`
(Vita, from the vito repo's `tools/`) and `picasso` (3DS). On its last run, 84 probes, **every 3DS
result matched this table**. See "What the probe found" at the end.

What a probe result means: `ok` = the compiler accepted the code. It does **not** prove the 3DS
lowering computes the right number, or that a Vita shader behaves the same on hardware. Those are
mbsc's own tests (S2 and later).

## Legend

| Mark | Meaning |
|---|---|
| `ok` | one native instruction, or a direct equivalent |
| `=` | exact, built from a few native instructions (the number is the cost) |
| `~` | *(no longer used)* mbsc never swaps an operation for a close one. A built-in is either exact on the target or an error; established behaviour (HLSL's `round`, `fmod`) is kept and made exact on every target |
| `x` | not possible: `MBS-E1` (vertex) or `MBS-E2` (fragment) |
| `?` | expected to work, not yet checked with that compiler |

## What each target is

| | PC (HLSL, SM 5.0) | Vita (Cg, `psp2cgc` -> `.gxp`) | 3DS vertex (PICA asm) | 3DS fragment (TexEnv) |
|---|---|---|---|---|
| Programmable | yes | yes | yes, small ISA | **no**: 6 fixed stages |
| Float registers | plenty | plenty | 96 `fvec` uniforms, 16 in, 16 out, 16 temps | |
| Integers | full | full | loop counters and index only (`i0`-`i3`, 8-bit) | |
| Booleans | full | full | 16 `bool` uniforms, 2 condition flags (`cmp.x`, `cmp.y`) | |
| Loops | any | any | `for` over a constant or integer uniform; no `while` | |
| Texture sample | yes | yes (vertex: `?`) | **no** | 3 units (TEXTURE0-2), result is a stage input |
| Derivatives | yes | `?` | n/a | n/a |
| Output precision | 32-bit | 32-bit (`half` possible) | 24-bit float | 8 bits per channel, each stage clamps to 0..1 |

## Arithmetic

| MBS | PC | Vita | PICA vertex | PICA fragment |
|---|---|---|---|---|
| `a + b`, `a - b` | ok | ok | ok (`add`; `-` negates a register, free) | ADD / SUBTRACT |
| `a * b` | ok | ok | ok `mul` | MODULATE |
| `a / b` | ok | ok | = 2 (`rcp`, `mul`) | x |
| `a * b + c` / `fma` | ok | ok | ok `mad` | MULTIPLY_ADD |
| `abs` | ok | ok | = 1 (`max(x, -x)`) | x |
| `min`, `max` | ok | ok | ok | x |
| `clamp`, `saturate` | ok | ok | = 2 (`max`, `min`); saturate also free on output? (probe) | each stage clamps 0..1 |
| `floor` | ok | ok | ok `flr` | x |
| `ceil` | ok | ok | = 3 (`-flr(-x)`) | x |
| `fract` (HLSL `frac`) | ok | ok | = 2 (`x - flr(x)`) | x |
| `trunc` | ok | ok | = about 5 (sign, abs, flr) | x |
| `round` | ok | ok | = 10: HLSL's rule, halves to the even neighbour (the disassembly shows `round_ne`); the lowering matched it on 200,000 values | x |
| `sign` | ok | ok | = 3 (`slt`, `slt`, `add`) | x |
| `fmod(x, y)` | ok | ok | = 11: HLSL's rule (sign of x / y, times frac(abs(x / y)), times y); the lowering matched it exactly | x |
| `mod(x, y)` | ok | ok | = 5: Odin's `linalg.mod`, `x - y * floor(x / y)` | x |
| `step(a, x)` | ok | ok | ok `sge` | x |
| `lerp` / `mix` | ok | ok | = 2 (`add`, `mad`) | INTERPOLATE |
| `smoothstep` | ok | ok | = about 6 | x |
| `sqrt` | ok | ok | = 2 (`rsq`, `rcp`); `sqrt(0)` needs a probe (`?`) | x |
| `inverse_sqrt` (HLSL `rsqrt`) | ok | ok | ok `rsq` | x |
| `rcp` | SM5 | **x** (no `rcp` in Cg: mbsc emits `1.0 / x`) | ok `rcp` | x |
| `exp2` | ok | ok | ok `ex2` | x |
| `log2` | ok | ok | ok `lg2` | x |
| `exp`, `ln` (HLSL `log`), `log10` | ok | ok | = 2 (`ex2`/`lg2` plus a constant `mul`) | x |
| `pow(x, y)` | ok | ok | = 3 (`ex2(y * lg2(x))`), defined for x > 0 | x |
| `sin`, `cos`, `tan` | ok | ok | **x**: `MBS-E1`; use `sin_approx` / `cos_approx` (D2) | x |
| `asin`, `acos`, `atan`, `atan2` | ok | ok | **x**: `MBS-E1`, compute on the CPU | x |
| `sinh`, `cosh`, `tanh` | ok | ok | x | x |
| `sincos` | ok | ok | x | x |
| `to_radians`, `to_degrees` (HLSL `radians`, `degrees`) | ok | ok | = 1 (`mul` by a constant) | x |
| `frexp` | ok | **x** (`sce_vp_psp2` rejects it) | x | x |
| `ldexp`, `modf` | ok | ok | x | x |
| `isnan`, `isinf`, `isfinite` | ok | ok | x | x |
| `noise` | **x** (not in SM5) | **x** | x | x: not a Matchbox built-in |

## Vectors and matrices

| MBS | PC | Vita | PICA vertex | PICA fragment |
|---|---|---|---|---|
| swizzle, write mask | ok | ok | ok, free | operand modifiers only (R, G, B, A, one-minus) |
| `dot` (2, 3, 4) | ok | ok | ok `dp3`, `dp4` (a vec2 uses `dp3` with a zeroed z) | DOT3_RGB (three components only) |
| `length` | ok | ok | = 3 (`dp3`, `rsq`, `rcp`) | x |
| `distance` | ok | ok | = 4 | x |
| `normalize` | ok | ok | = 3 (`dp3`, `rsq`, `mul`) | x |
| `cross` | ok | ok | = 3 (`mul`, `mad` with swizzles) | x |
| `reflect`, `refract` | ok | ok | = about 4 / 12 | x |
| `faceforward` | ok | ok | = about 5 | x |
| `lit` | ok | ok | ok `litp` is related; exact match needs a probe (`?`) | lighting unit is separate |
| `matrix * vector` | ok | ok | = 4 `dp4` (the engine's own transform) | x |
| `vector * matrix` | ok | ok | = 4 `dp4` on transposed uniforms | x |
| `matrix * matrix` | ok | ok | = 16 `dp4`, and eats uniforms; do it on the CPU | x |
| `transpose` | ok | ok | free only on uniforms (the CPU can upload it transposed) | x |
| `determinant`, `inverse` | ok | `?` | x: do it on the CPU | x |
| vec3 matrices (`matrix[3,3]f32`) | ok | ok | 3 registers (3 rows) | x |

## Flow control and selection

| MBS | PC | Vita | PICA vertex | PICA fragment |
|---|---|---|---|---|
| `if` on a bool uniform | ok | ok | ok `ifu` | x |
| `if` on a comparison | ok | ok | ok `cmp` + `ifc` (2 flags) | x |
| `cond ? a : b` / `select` | ok | ok | = 3 (`sge`, `add`, `mad`: branchless) | x |
| `for` with constant or integer-uniform count | ok | ok | ok | x |
| `while`, dynamic loop count | ok | ok | **x** (`MBS-E7`) | x |
| `discard` | ok | ok | x in vertex | alpha test only, one 8-bit ref, 8 comparisons (`MBS-E12`) |
| `break` | ok | ok | ok `breakc` (not recommended) | x |
| procedure calls | ok | ok | ok `call` (inlined by default) | x |

## Textures

| MBS | PC | Vita | PICA vertex | PICA fragment |
|---|---|---|---|---|
| `sample(tex, uv)` | ok | ok | **x** (`MBS-E8`) | ok: a stage source (TEXTURE0-2) |
| `sample_lod`, `sample_bias`, `sample_grad` | ok | ok / `?` | x | x |
| `sample` with a computed `uv` | ok | ok | n/a | **x**: uv comes from the vertex stage's texcoord output |
| cube / 3D textures | ok | ok / `?` | x | cube: `?` (units only) |
| `ddx`, `ddy`, `fwidth` | ok | ok / `?` | x | x |

## Data types

| MBS | PC | Vita | PICA vertex |
|---|---|---|---|
| `f32`, `[2..4]f32` | ok | ok | ok (24-bit) |
| `f16` | min precision hint | `half`: ok | treated as `f32` |
| `i32`, `u32`, `[N]i32` | ok | ok | **only as loop counters and indexes**: `MBS-E9` |
| `bool` | ok | ok | uniforms only, plus the 2 condition flags |
| `matrix[N, M]f32` | ok | ok | rows of `fvec`; max 24 `mat4` |
| uniform arrays, constant index | ok | ok | ok |
| uniform arrays, dynamic index | ok | ok | one index source, float uniforms only (`MBS-E10`) |
| `struct` | ok | ok | fine: flattened to registers |

## Varyings (vertex to fragment)

| | PC | Vita | 3DS |
|---|---|---|---|
| position | `SV_POSITION` | `POSITION` | `position` |
| colour | any | any | `color` |
| texcoords | any number | up to 8 `TEXCOORD`s (`?`) | `texcoord0` (2 components), `texcoord0w`, `texcoord1`, `texcoord2` |
| other data | any, up to 32 vec4s | up to 10 (`?`) | **none**: the fragment stage reads only colour and texcoords (`MBS-E6`) |

This is the biggest design consequence: on the 3DS a varying that isn't colour or a texcoord has nowhere to go.

## 3DS TexEnv, exactly what a fragment stage can be

Six stages. Each stage: up to three sources, a function, an operand per source, a scale, and separate RGB and alpha settings.

- **Sources:** primary colour (vertex colour), fragment primary and secondary (lighting unit), TEXTURE0, TEXTURE1, TEXTURE2, TEXTURE3 (procedural texture), previous stage, previous buffer, a constant colour.
- **Functions:** REPLACE, MODULATE, ADD, ADD_SIGNED, INTERPOLATE, SUBTRACT, DOT3_RGB, **DOT3_RGBA**, MULTIPLY_ADD, ADD_MULTIPLY. (`DOT3_RGBA` is in citro3d but not yet in the o3dx binding in this repo, which skips value 7. Decided 2026-11-18: the spec assumes it is added, and mbsc may use it.)
- **Operands:** colour, one-minus colour, alpha, one-minus alpha, and single channels R, G, B (and one-minus).
- **Scale:** x1, x2, x4.
- **After the stages:** alpha test (8 comparisons: never, always, equal, not equal, less, less-equal, greater, greater-equal; one 8-bit reference), then blend.

## What picasso actually enforces (probed on this machine)

| Rule | picasso says |
|---|---|
| a uniform as the second source of `mul` | error: `invalid source2 register: k` |
| two different input registers in one instruction | error: `source operands must be different input registers (v0..v15)` |
| two consecutive `mova` | **no error**; the hardware freezes. The generator must prevent it itself |
| plain `dp4` group into `o0.x` .. `o0.w` | assembles |

So: the "constant as first operand only" rule in the plan is picasso's "wide" first operand rule, and the generator
must pick operand order (and swap for commutative ops) to satisfy it. Hazards picasso doesn't catch (`mova`
pairs, the reversed-component `dp4` into a temp) are on us.

## Decisions this surfaces

- **D1. Tiers.** Core = everything marked `ok`, `=` or `~` on PICA vertex, so it works on all three targets. Extended = works on PC and Vita but errors on the 3DS vertex. PC-only (atomics, bit ops, compute, tessellation, `abort`, `printf`) is out of scope entirely.
- **D2. Transcendentals on the 3DS. DECIDED 2026-11-18.** No silent approximation, anywhere. `sin`, `cos` and the rest of the `x` rows are compile errors on the 3DS, and the message says what will work instead (`MBS-E1`). `sin_approx` and `cos_approx` are explicit built-ins, available on every target, that state their maximum error in the spec. A shader that calls them looks the same on all three. The error's `help` line points at them.
- **D3. Integers on the 3DS.** Keep `i32` in the language, error on arithmetic (`MBS-E9`), allow loop counters and indexes.
- **D4. Varyings.** Keep free-form varyings in the language and error on the 3DS (`MBS-E6`), or restrict varyings to colour and texcoords everywhere so every shader is portable by default. Recommendation: the first, with an error that explains how to pack.

## What the probe found (run 2026-11-18, 84 probes)

Run it with `odin run tools/mbsc_probe.odin -file -- -psp2cgc:<path> -out:report.md`.

**Vita (`psp2cgc`, profiles `sce_vp_psp2` and `sce_fp_psp2`), where it differs from "ordinary Cg":**

| Built-in | Result | What mbsc does |
|---|---|---|
| `rcp` | **rejected**: Cg has no `rcp` | emit `1.0 / x` |
| `frexp` | **rejected**: `profile 'sce_vp_psp2' does not support 'frexp()'` | `MBS-E1` on Vita as well |
| `noise` | rejected on PC (`cannot map expression to vs_5_0`) and on Vita | **not a Matchbox built-in** |
| `inverse` | no such function on PC, Vita or 3DS | not a built-in; compute on the CPU |
| `refract` | accepted, but only with `float3` arguments (a `float4` call is a type error) | the front end checks the types |

Accepted on Vita: `sin`, `cos`, `tan`, the inverse and hyperbolic trig, `sincos`, `ldexp`, `modf`, `isnan`, `isinf`,
`isfinite`, `determinant`, `ddx`, `ddy`, `fwidth`, `discard`, `clip`, `tex2Dlod` in the **vertex** stage,
`tex2Dbias`, and the gradient `tex2D`. Compile acceptance only; vertex texture fetch and derivatives still need
to be seen on hardware before a game relies on them.

**3DS (`picasso`):**

- Every built-in marked `x` is refused with `invalid instruction: <name>`, which confirms the instruction does not exist.
  That covers `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `sincos`, `frexp`, `ldexp`,
  `modf`, `isnan`, `isinf`, `isfinite`, `noise`, `determinant`, `inverse`, vertex `tex`, and `while`.
- Every lowering marked `ok`, `=` or `~` assembles. `for` over `.consti cnt(4, 0, 1, 0)` (**four** values: an
  integer uniform has x, y, z, w) assembles, `for` over a float register fails with `invalid integer vector uniform: r1`.
- The probe caught one wrong lowering of mine: `faceforward` used `-one`. picasso refuses it
  (`invalid source2 register: -one`) because a constant can't be the second source or be negated. The fix is to copy the constant
  into a register first (`mov r5, one`, then `-r5`). mbsc's code generator has to know this: **constants go
  in a register before they are negated or used as a second operand**.

**PC (`d3dcompiler`, `vs_5_0` / `ps_5_0`):** everything is accepted except `noise` and `inverse`.

## Keeping the table honest

Re-run the probe when a compiler or the table changes. It exits with 1 if any 3DS result stops matching the table,
so it can run in a script. mbsc's own tests (S1 onwards) should call the same snippets so a lowering that
stops assembling fails the build.

## What mbsc checks per target (S7)

`mbsc shader.mbs --check` with no `-target:` checks the shader for the PC, the Vita and the 3DS and says what
compiles where:

```
shader.mbs:
  pc    ok: compiles to HLSL
  vita  ok: passes the checks; the Cg backend comes with S4
  3ds   2 problems
```

A mistake every target shares is printed once under `all targets:`; the rest are grouped under the target that
gives them. The exit code is 0 only when every target passes. With `-target:`, one target is checked as before.

Checked today (`tools/mbsc/capability.odin`, found in the code each stage reaches, so a helper is judged by the stage
that calls it):

| Error | What | Target |
|---|---|---|
| `MBS-E1` | a built-in the vertex unit lacks (`sin`, `cos`, `tan`, `asin`, ..., `ldexp`, `is_nan`, `is_inf`, `transpose`, `determinant`) or `m * n` | 3DS vertex |
| `MBS-E2` | a built-in in fragment code that is not `sample`, `lerp`, `saturate`, `dot3_signed` or `discard` | 3DS fragment |
| `MBS-E4` | more than 96 float uniform registers read by the vertex stage (engine blocks count by their declared fields) | 3DS |
| `MBS-E6` | a vertex output with no `out:` tag | 3DS |
| `MBS-E8` | `sample` or `sample_lod` in the vertex stage | 3DS |
| `MBS-E9` | `+ - * /` on whole numbers in the vertex stage | 3DS |
| `MBS-E10` | an index that is not a constant or a loop counter, in the vertex stage | 3DS |
| `MBS-E11` | a condition with more than two comparisons, in the vertex stage | 3DS |
| `MBS-E12` | a `discard()` that is not `if color.a < reference { discard() }` straight before `return color` | 3DS |
| `MBS-E19` | more than three textures sampled in the fragment stage | 3DS |
| `MBS-E20` | a `sample` coordinate in `fragment_main` that is not `v.<field>` tagged `texcoord0` to `texcoord2` | 3DS |
| `MBS-E28` | what HLSL can't write (array result, array literal argument, a sampling helper in both stages), and a struct uniform written inline | PC (the last one every target) |

Not checked yet, because they need what a backend makes of the shader (S5, S6): `MBS-E3` and `MBS-E5` (combiner
stages, registers and temporaries), `MBS-E21` (two different constants in one combiner stage), and the shapes of
the 3DS fragment stage beyond the built-in list (`MBS-E2` for a structure that won't fit TexEnv). The Vita has no
checks of its own: it takes the same code as the PC.
