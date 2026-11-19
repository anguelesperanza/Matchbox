# The reflection file

A built shader comes with a small text file that tells the runtime what the shader needs: which registers the
constant buffers are in, where each uniform sits inside its buffer, which slot each texture is bound to, and which
vertex attributes it reads. The runtime reads this file instead of hard-coding any of it, so a shader can change
without the engine changing.

```
mbsc shader.mbs -target:pc --emit-reflection -o:shader.pc.refl
```

The engine's own copy is `matchbox/shaders/mesh.pc.refl`, made from `matchbox/shaders/mesh.mbs` and committed next to
`mesh.pc.hlsl`. A test fails when either is out of date. For the Vita and the 3DS, `--emit-reflection` comes with
their backends (S4 to S6); the format is the same, with the registers of that target.

## Format

One entry per line; the words of a line are separated by single spaces; blank lines are ignored. Names and types
contain no spaces. The first line says which version of the format it is.

```
mbs-reflection 1
target pc

attribute position [3]f32
attribute texcoord [2]f32
attribute color [4]f32

block frame 0 80
block draw 1 112
block game 2 64

value frame view_projection matrix[4,4]f32 0 64 0 0
value frame time f32 64 4 0 0
value game palette [4]f32 16 64 4 16

texture tex 0
sampler 0
```

| Line | Meaning |
|---|---|
| `mbs-reflection <version>` | always the first line; the version is 1 |
| `target <name>` | `pc` |
| `attribute <name> <type>` | a vertex attribute the vertex stage reads, in the order of the vertex input struct. `<name>` is the `attr:"name"` tag |
| `block <name> <register> <size>` | a constant buffer: `frame`, `draw` or `game`, the register it is bound to (`b0` is register 0), and its size in bytes, a multiple of 16. Only the blocks the shader declares are listed |
| `value <block> <name> <type> <offset> <size> <count> <stride>` | one value the runtime can set inside a block |
| `texture <name> <slot>` | a texture and the slot it is bound to |
| `sampler <register>` | the register of the one sampler every texture is read through |

### `value`

- `<name>` is the uniform's name. A field of a struct is `key_light.strength`; an element of an array of structs is
  `lights[1].strength`. The fields of `frame` and `draw` are named plainly: `time`, `tint`.
- `<type>` is the value's type: `f32`, `i32`, `u32`, `bool`, `[2]f32` to `[4]f32`, `[2]i32` to `[4]i32` or
  `matrix[R,C]f32`. For an array of numbers, vectors or matrices it is the type of **one element**.
- `<offset>` is where the value starts in the block, in bytes. `<size>` is the bytes it takes: for an array, all of
  its elements together, the last without padding.
- `<count>` and `<stride>` are `0 0` for a value that isn't an array. Otherwise `count` elements follow each other
  `stride` bytes apart.
- An array of structs, or of arrays, is written one element per line, each with `0 0`.
- A matrix is stored by columns, as the engine uploads it: column `c` starts at `offset + 16 * c` and takes
  `R * 4` bytes. A `matrix[4,4]f32` is 64 bytes, a `matrix[3,3]f32` is 44 (two full columns and 12 bytes).

### Where values go

The offsets are what HLSL packs, and a test compares every one with d3dcompiler's own answer:

- a scalar or a vector goes where it fits without crossing a 16-byte boundary
- a matrix, an array or a struct starts on a 16-byte boundary
- each array element starts on a 16-byte boundary
- what comes after a matrix, array or struct may share its last 16 bytes if there is room

The engine blocks list **every** field of the engine's own layout (`Frame_Constants`, `Draw_Constants`), whichever of
them the shader declared, because the runtime fills one fixed struct. The runtime checks its struct against these
lines when it starts and stops with a message if they disagree.

PC lists every uniform and texture the shader declares, used or not, because HLSL's layout doesn't drop an unused one.
The Vita and the 3DS drop what is unused, and their files will list only what remains.
