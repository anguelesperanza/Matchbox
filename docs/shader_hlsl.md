# The HLSL backend of mbsc

For the PC target, `mbsc` writes the intermediate form (`docs/shader_ir.md`) as Shader Model 5 HLSL, which the
engine compiles with d3dcompiler at startup.

```
mbsc shader.mbs -target:pc --emit-hlsl
```

prints the HLSL, and `-o:<file>` writes it to a file instead. The engine's `matchbox/shaders/mesh.pc.hlsl` is made
this way from `matchbox/shaders/mesh.mbs`, committed, and checked by a test. A shader with errors prints
the errors and no HLSL. The Vita and the 3DS don't take HLSL, so `--emit-hlsl` with another target is a usage error.

## What the output looks like

```
struct Vertex_In { ... };            the shader's structs, each after the ones it contains
cbuffer frame_block : register(b0)   the engine's frame block
cbuffer render_block  : register(b1)   the engine's render block
cbuffer mbs_game    : register(b2)   the game's own uniforms, in the order they are declared
Texture2D tex : register(t0);        one per @(texture = N), at register tN
SamplerState mbs_sampler : register(s0);
<helpers for building structs>
<procedures, callees first>          vertex_main and fragment_main are the entry points
```

`tools/mbsc/testdata/mesh_pc.hlsl` is the output for `tools/mbsc/testdata/mesh.mbs`, and a test checks that they
still agree.

## Rules of the translation

| In the shader | In the HLSL |
|---|---|
| `frame.view_projection`, `render.tint` | `frame_view_projection`, `render_tint`: HLSL puts the fields of a constant buffer in the global scope, so each is named `<block>_<field>` |
| the engine blocks | written with **every** engine field, in the engine's order, whichever fields the shader declared: the runtime fills one fixed layout (`Frame_Constants`, `Render_Constants`), and the buffer must match it |
| `m * v`, `v * m`, `m * n` | `mul(m, v)`, `mul(v, m)`, `mul(m, n)`. The engine uploads Odin's matrix layout, which HLSL reads as column-major, so this is the same product. HLSL's own `*` works per element, so it is used only for `m * 2.0` and `m + n` |
| `[4]f32`, `matrix[4, 4]f32`, `i32`, `u32` | `float4`, `float4x4`, `int`, `uint` |
| `x: T` | `T x = (T)0;` |
| `T{a, b}` for a vector or matrix | `float3(a, b, c)`, `float4x4(...)` |
| `Light{...}` | a call to `mbs_make_Light(...)`, a small function written once per struct the shader builds, since HLSL has no struct constructor |
| `a := [5]f32{...}` | `float a[5] = { ... };`. An array written as a value is only possible as the start of a variable |
| `f32(x)`, `i32(x)` | `((float)(x))`, `((int)(x))` |
| `for i in 0..<n` / `0..=n` | `for (int i = 0; i < n; i++)` / `i <= n` |
| `sample(tex, uv)`, `sample_lod`, `sample_bias`, `sample_grad` | `tex.Sample(mbs_sampler, uv)`, `SampleLevel`, `SampleBias`, `SampleGrad` |
| `discard()` | `discard;` |
| `inverse_sqrt`, `ln`, `fract`, `to_radians`, `to_degrees`, `is_nan`, `is_inf` | `rsqrt`, `log`, `frac`, `radians`, `degrees`, `isnan`, `isinf` |
| `sign(x)` | `((float)sign(x))`, because HLSL's `sign` gives an `int` |
| `mod(a, b)` | `mbs_mod(a, b)`, a function written once per type: `a - b * floor(a / b)`, the sign of `b` like Odin's `mod`. HLSL's `fmod` takes the sign of `a`, so it is not used |
| `sin_approx(x)`, `cos_approx(x)` | `mbs_sin_approx(x)`, `mbs_cos_approx(x)`: the polynomial of section 15 of the language reference, the same on every target |
| `dot3_signed(a, b)` | `(4.0 * dot(a.xyz - 0.5, b.xyz - 0.5))` (the `.xyz` only for a `[4]f32`) |
| `sample(tex, uv)` in the vertex stage | `tex.SampleLevel(mbs_sampler, uv, 0.0)`: that stage has no derivatives to choose a mip level with |
| `when` | already settled: only the branch for the target is written |

The reflection file that goes with the HLSL (`--emit-reflection`, `docs/shader_reflection.md`) lists the registers
above and the offset of every uniform inside its buffer, by the packing rules of HLSL's constant buffers. A test
compares those offsets with d3dcompiler's own.

Semantics: a field tagged `attr:"name"` gets the semantic `name`, and `out:"position"`, `"color"`,
`"texcoord0"` to `"texcoord2"` get `SV_POSITION`, `COLOR` and `TEXCOORD0` to `TEXCOORD2`. The fragment entry point
returns `: SV_TARGET`.

Names: a name of the shader that is an HLSL word or intrinsic (`sample`, `point`, `line`, `lerp`, ...) gets `mbs_`
in front of it. A local variable whose name is already taken in its procedure, or at the top level, gets its number
added (`x_3`).

## What is not written yet

mbsc says so instead of guessing, and prints no HLSL:

Each of these is an `MBS-E28` error with a source position, found before the backend runs (S7):

- A procedure that calls `sample` and runs in both the vertex and the fragment stage: HLSL samples differently in
  each. Give each stage its own copy.
- A procedure that returns an array, an array literal passed to a procedure, and a game uniform that is a struct
  written inline.

The backend still says "can't write this shader" for the same cases if one ever slips past the check, so a bug in
the check can't produce HLSL that doesn't compile.

A field of the vertex output with no `out:` tag gets a `TEXCOORD` semantic from `TEXCOORD3` upward, so the stages
can pass it on. (The 3DS has no such output, which is `MBS-E6` there.)
