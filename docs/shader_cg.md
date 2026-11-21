# The Cg backend (Vita)

> **Hardware status:** this has only been tested on emulators so far (Vita3K). It still needs to be tested on real hardware (a PS Vita) before it can be considered working.


`mbsc shader.mbs -target:vita --emit-cg -o:name` writes `name_v.cg` and `name_f.cg`. The Vita's compiler (`psp2cgc`, in the vito repo) turns each into a `.gxp`. Each file holds only the procedures reachable from its own stage.
`--emit-reflection` with `-target:vita` writes the `.vita.refl` file the runtime reads.

## What the Vita does differently from the PC

- **No constant buffers.** Every engine and game uniform is a global `uniform` parameter. Engine fields are named `<block>_<field>` (`frame_view_projection`, `render_model`, `render_tint`). A game uniform keeps its own name.
- **Struct and array uniforms** appear in the `.gxp` parameter table as dotted leaves (`key_light.strength`, `lights[1].color`). Arrays are one parameter with an array count.
- **Textures** are `uniform sampler2D name : TEXUNIT<slot>`.
- **Entry point** is a `main` wrapper. The vertex program takes attributes as plain parameters named `a_<attribute>` and writes `out` parameters tagged `POSITION`, `TEXCOORDn`, `COLOR0`. The fragment program takes `i_<field>` (`POSITION` is `WPOS`) and returns `: COLOR`. Varyings with no tag (and `NORMALQUAT`, `VIEW`) get `TEXCOORD3` and up.
- **Matrices.** Odin matrix memory read by Cg is transposed, so Odin `matrix[R,C]` becomes Cg `float{C}x{R}`, `m*v` becomes `mul(v,m)`, `v*m` becomes `mul(m,v)`, `m*n` becomes `mul(n,m)`, and matrix literals are written transposed. The runtime passes Odin matrix memory unchanged.
- **Clip space is OpenGL style (z from -1 to 1)**, so the Vita runtime must build GL-style projections.
- **Sampling.** Vertex stage: `tex2Dlod(tex, float4(uv,0,0))`. Fragment: `tex2D`. `sample_lod`, `sample_bias` and `sample_grad` map to `tex2Dlod`, `tex2Dbias`, `tex2D` with gradients.
- **`round`** is a helper (`mbs_round`) because Cg rounds halves away from zero. `step` and `smoothstep` with a scalar edge are broadcast.
- **Not written yet** (reported as problems, not guessed): procedures that return arrays, and structs written inline as uniforms (also E28).

## Checks

The tests compile every built-in, the shipped shaders and `testdata/uniforms.mbs` with the real `psp2cgc` (found through `PSP2CGC` or `../vito/tools/psp2cgc.exe`; the tests skip when it isn't there). The generated mesh programs were also run in Vita3K: matrices, `uv_rectangle`, alpha cut-off, vertex colour and texture all drew correctly.

Regenerate the committed mesh shaders after changing the compiler or `mesh.mbs`:

```
mbsc matchbox/shaders/mesh.mbs -target:vita --emit-cg -o:matchbox/shaders/mesh
psp2cgc -profile sce_vp_psp2 matchbox/shaders/mesh_v.cg -W4 -nocolor -o matchbox/shaders/mesh_v.gxp
psp2cgc -profile sce_fp_psp2 matchbox/shaders/mesh_f.cg -W4 -nocolor -o matchbox/shaders/mesh_f.gxp
mbsc matchbox/shaders/mesh.mbs -target:vita --emit-reflection -o:matchbox/shaders/mesh.vita.refl
```

A test fails when the committed `mesh_v.cg`, `mesh_f.cg` or `mesh.vita.refl` is out of date.

## Vita reflection (format v1)

```
mbs-reflection 1
target vita
attribute <attr> <type>
uniform <name> <type> <count>
texture <name> <slot>
```

There are no blocks, offsets or sampler lines. `<name>` is the Cg global (`frame_view_projection`) or the game uniform's dotted/indexed leaf name; `<count>` is 0 for a single value, the length for an array.
