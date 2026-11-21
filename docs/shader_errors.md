# Matchbox shader errors

Every error `mbsc` (the Matchbox Shader Compiler) can report has a number, `MBS-E<n>`. Warnings are `MBS-W<n>`.
This file explains each one: what it means, why the compiler refuses, and how to fix it.

- Numbers are **never reused or renumbered**. A retired error keeps its number and is marked *retired*.
- New errors take the next free number.
- `mbsc --explain MBS-E1` prints the matching entry from this file.
- **No silent approximation.** If a target can't do something, mbsc fails with one of these errors and says what
  *will* work. Nothing is quietly replaced by something close.
- Every message ends with a link line pointing here, for example `docs/shader_errors.md#mbs-e1`.

## What an error looks like

Modelled on rustc. An error says what is wrong, points at the exact code, says *why* in the
note, and gives a concrete fix when there is one:

```
error[MBS-E1]: `sin` is not available in 3DS vertex shaders
  --> hit_flash.mbs:12:25
   |
12 |         return 0.75 + 0.25 * sin(time * 8)
   |                              ^^^ no sine instruction on this target
   |
   = note: building for `3ds`: the PICA200 vertex unit has no sin, cos, sqrt, pow or divide instruction
   = help: `when TARGET == .PICA200 { return 1 } else { ... }` gives the 3DS its own version
   = help: or use `sin_approx(x)`, a polynomial that works everywhere (max error 0.001, documented in the spec)
   = more: docs/shader_errors.md#mbs-e1
```

Rules for writing a message:

1. Line one says what is wrong in plain words, with the name of the thing and the target.
2. The label under the code says what *that piece of code* is doing wrong, in few words.
3. `note` gives the reason: the hardware or language rule behind it, never "because the compiler says so".
4. `help` gives a fix the author can apply. Several are fine. If there is no fix, say so in the note.
5. When a fix is a code edit, show the edited line, as rustc does.
6. A shader that fails on one target still builds for the others; the message names the target that failed.

## Index

| Code | Title |
|---|---|
| [MBS-E1](#mbs-e1) | Built-in not available on this target (vertex) |
| [MBS-E2](#mbs-e2) | Fragment code is outside the 3DS portable subset |
| [MBS-E3](#mbs-e3) | Fragment needs more than 6 combiner stages |
| [MBS-E4](#mbs-e4) | Too many uniforms for the target |
| [MBS-E5](#mbs-e5) | Too many inputs, outputs or temporaries |
| [MBS-E6](#mbs-e6) | Varying has no hardware output on this target |
| [MBS-E7](#mbs-e7) | Loop bound is not a constant |
| [MBS-E8](#mbs-e8) | Texture sample in a vertex shader |
| [MBS-E9](#mbs-e9) | Integer arithmetic not available on this target |
| [MBS-E10](#mbs-e10) | Array index is not a constant or a loop counter |
| [MBS-E11](#mbs-e11) | Condition too complex for the target |
| [MBS-E12](#mbs-e12) | `discard` is not an alpha test the target can do |
| [MBS-E13](#mbs-e13) | Type mismatch |
| [MBS-E14](#mbs-e14) | Name not found |
| [MBS-E15](#mbs-e15) | Missing or wrong entry point |
| [MBS-E16](#mbs-e16) | Odin feature not available in shaders |
| [MBS-E17](#mbs-e17) | Recursion |
| [MBS-E18](#mbs-e18) | Unknown engine uniform field |
| [MBS-E19](#mbs-e19) | More than 3 textures in a 3DS fragment shader |
| [MBS-E20](#mbs-e20) | Texture coordinate is not a plain texcoord varying |
| [MBS-E21](#mbs-e21) | Two different constants needed in one combiner stage |
| [MBS-E22](#mbs-e22) | Syntax error |
| [MBS-E23](#mbs-e23) | `when` condition can't be decided |
| [MBS-E24](#mbs-e24) | Unknown or misplaced attribute or tag |
| [MBS-E25](#mbs-e25) | Declared twice |
| [MBS-E26](#mbs-e26) | Fragment-only built-in used in the vertex stage |
| [MBS-E27](#mbs-e27) | Assignment to something read-only |
| [MBS-E28](#mbs-e28) | The PC backend can't write this |

Reserved for later (numbers are taken now so they stay stable): none yet.

---

## MBS-E1

**Built-in not available on this target (vertex)**

```
error[MBS-E1]: `pow` is not available in 3DS vertex shaders
  --> glow.mbs:20:17
   |
20 |     let k = pow(base, 4.0)
   |             ^^^ no pow instruction on this target
   |
   = note: the PICA200 vertex unit has ex2 and lg2 but no pow
   = help: pow(x, y) is exp2(y * log2(x)) when x > 0; write that if x is never negative
   = more: docs/shader_errors.md#mbs-e1
```

**Why.** The PICA200 vertex unit has a small instruction set: add, mul, mad, dp3, dp4, dph, dst,
min, max, flr, rcp, rsq, ex2, lg2, sge, slt, litp, mov and compare. A built-in marked `x` or `~` in the
capability table (`shader_language.md`, built-ins) has no instruction, or only an inexact one.

**Fix.** Use a built-in marked `ok` or `=` (lowered exactly), wrap the code in
`when TARGET == .PICA200 { ... } else { ... }`, or use the `_approx` version where one exists.

---

## MBS-E2

**Fragment code is outside the 3DS portable subset**

```
error[MBS-E2]: this fragment expression can't run on the 3DS
  --> tint.mbs:31:12
   |
31 |     return sample(tex, v.uv) * pow(v.color, [4]f32{2.2, 2.2, 2.2, 1})
   |                               ^^^ pow is not a texture combiner operation
   |
   = note: the 3DS has no pixel shader. Its fragment stage is up to 6 fixed combiner stages, each of
           REPLACE, MODULATE, ADD, ADD_SIGNED, INTERPOLATE, SUBTRACT, DOT3_RGB, DOT3_RGBA, MULTIPLY_ADD or ADD_MULTIPLY
   = help: do the pow in the vertex shader and pass the result as `color`
   = help: or provide a 3DS version: `when TARGET == .PICA200 { return sample(tex, v.uv) * v.color }`
   = more: docs/shader_errors.md#mbs-e2
```

**Why.** The portable fragment subset is: sample a texture, read the vertex colour, a constant colour or the
previous stage, and combine them with `*`, `+`, `-`, `lerp`, `a * b + c`, `(a + b) * c`, `a + b - 0.5` or
`dot3_signed`, one operation per stage (part 3, sections 17 and 18). Anything else has no combiner mode. That
includes a computed value used more than once, because a stage can read only the stage before it, and the
hardware lighting sources, which are reserved.

**Fix.** Move the work to the vertex stage, simplify the expression, or give the 3DS its own branch.

---

## MBS-E3

**Fragment needs more than 6 combiner stages**

```
error[MBS-E3]: this fragment shader needs 8 combiner stages; the 3DS has 6
  --> layered.mbs:40:5
   |
40 |     color = lerp(color, sample(b, v.uv), 0.5) * sample(c, v.uv) + v.color
   |     ^^^^^ stage 7 is needed here
   |
   = note: each operation takes one stage, and the 3DS has 6
   = help: combine textures into one before the game uses them (the sprite packer can bake this)
   = more: docs/shader_errors.md#mbs-e3
```

**Why.** TexEnv has exactly 6 stages, and each does one combine of up to three inputs. Three shapes fuse into one
stage (`a * b + c`, `(a + b) * c`, `a + b - 0.5`), and the colour and alpha halves of a stage run together, so
the count is usually lower than the number of operators (part 3, section 18).

**Fix.** Fewer operations, or bake layers into one texture offline.

---

## MBS-E4

**Too many uniforms for the target**

```
error[MBS-E4]: this shader uses 104 uniform registers; the 3DS has 96
   |
   = note: a `matrix[4, 4]f32` takes 4 registers, a `[4]f32` takes 1, a `[3]f32` takes 1
   = note: `frame` uses 4, `render` uses 7, `lights` uses 93
   = help: `lights` is the largest; lower its array length
   = more: docs/shader_errors.md#mbs-e4
```

**Why.** The PICA200 has 96 float vector uniform registers (c0 to c95). Each vector, even a single `f32`, takes a
whole register unless the compiler can pack scalars together.

---

## MBS-E5

**Too many inputs, outputs or temporaries**

```
error[MBS-E5]: this vertex shader needs 19 temporary registers; the 3DS has 16
   |
   = note: the PICA200 has 16 input (v), 16 output (o) and 16 scratch (r) registers
   = help: split long expressions into separate statements so values stop being live sooner
   = more: docs/shader_errors.md#mbs-e5
```

**Why.** Fixed register files. The compiler reuses temporaries as soon as a value is dead, so this only
fires when too many values are live at the same moment.

---

## MBS-E6

**Varying has no hardware output on this target**

```
error[MBS-E6]: field `world_normal` has no place to go on the 3DS
  --> lit.mbs:8:5
   |
 8 |     world_normal: [3]f32,
   |     ^^^^^^^^^^^^ no output semantic for this field
   |
   = note: the 3DS vertex shader can only output position, colour, texcoord0 to texcoord2, normalquat and view
   = note: and the fragment stage can only read colour and texcoords, so custom varyings can't reach it
   = help: pack the data into `color` or a `texcoord`: `texcoord1: [2]f32 `out:"texcoord1"``
   = more: docs/shader_errors.md#mbs-e6
```

**Why.** The fragment stage has fixed inputs (primary colour, texcoords, lighting). There is no way to
send arbitrary data from the vertex shader to it.

---

## MBS-E7

**Loop bound is not a constant**

```
error[MBS-E7]: this loop's count isn't known when the shader is built
  --> blur.mbs:15:5
   |
15 |     for i in 0..<render.samples {
   |         ^^^^^^^^^^^^^^^^^^^^^^^ `render.samples` is a float uniform
   |
   = note: the PICA200 only loops with a count that is a constant or an integer uniform (i0 to i3, 8 bits)
   = help: declare `@(uniform) samples: u8` to make it an integer uniform
   = help: or use a constant: `for i in 0..<4`
   = more: docs/shader_errors.md#mbs-e7
```

A bound is accepted when it is a literal, a constant, arithmetic on constants, or an `i32` uniform. Anything else
(a local variable, an expression that mentions a uniform) is this error.

**Why.** The hardware loop reads its count from an 8-bit integer register. There is no general `while`.

---

## MBS-E8

**Texture sample in a vertex shader**

**Why.** The PICA200 vertex unit can't read textures. PC and Vita can, but a shader that does it can't
build for the 3DS. **Fix.** Sample in the fragment stage, or put the lookup in a `when TARGET` branch.

---

## MBS-E9

**Integer arithmetic not available on this target**

**Why.** The PICA200 vertex unit has no integer ALU. Integers exist only as loop counters (i0 to i3) and
as indexes into uniform arrays. `a + b` on two `i32` values is an error there.
**Fix.** Use `f32`, or keep the integer as a loop counter only.

---

## MBS-E10

**Array index is not a constant or a loop counter**

**Why.** Indexing a uniform array with anything other than a constant, a loop counter or one of the two
address registers is not possible. Also, only one operand of an instruction can use an index register.
**Fix.** Loop over the array, or use constants.

---

## MBS-E11

**Condition too complex for the target**

**Why.** The PICA200 has two condition flags, `cmp.x` and `cmp.y`, set by one `cmp`. A condition can combine
those two with `&&` or `||`; a third comparison has nowhere to live. **Fix.** Nest `if`s, or use `lerp` and
`step` for a branchless result.

---

## MBS-E12

**`discard` is not an alpha test the target can do**

```
error[MBS-E12]: this `discard` isn't an alpha test
  --> leaf.mbs:34:5
   |
34 |     if sample(mask, v.uv).r < 0.5 do discard()
   |        ^^^^^^^^^^^^^^^^^^^^^^^^^^ the condition isn't the alpha of the returned colour
   |
   = note: on the 3DS `discard` is the hardware alpha test: one comparison of the final alpha with one reference
   = help: put the mask in the alpha channel and test it: `color.a = sample(mask, v.uv).r` then
           `if color.a < 0.5 do discard()`
   = more: docs/shader_errors.md#mbs-e12
```

**Why.** On the 3DS `discard` turns into the alpha test state: compare the final alpha with one 8-bit
reference value, using one of 8 comparisons. `if color.a < render.alpha_cutoff do discard()` becomes exactly
that. The test must be on the alpha of the colour the shader returns, against a literal or an `f32` fragment
uniform, and be the last statement before the `return`. `discard` on any other condition, in any other place,
has no mapping (part 3, section 19). **Fix.** Express the cut as an alpha comparison.

---

## MBS-E13

**Type mismatch**

```
error[MBS-E13]: mismatched types
  --> a.mbs:9:20
   |
 9 |     out.uv = in.position
   |              ^^^^^^^^^^^ expected `[2]f32`, found `[3]f32`
   |
   = help: take two components: `in.position.xy`
   = more: docs/shader_errors.md#mbs-e13
```

**Why.** The language has no implicit conversions, so mixing numbers is the most common way to get this. `1` is an
`i32` and `1.0` is an `f32`; `render.tint * 2` is this error and `render.tint * 2.0` is not. The same error covers a
built-in called with the wrong types or number of arguments, a procedure called with the wrong arguments, a
`return` of the wrong type, a function that doesn't return a value on every path, and a swizzle that doesn't fit
the vector (`.w` on a `[3]f32`). After one error in an expression, the expressions around it stay quiet, so one
mistake gives one message.

---

## MBS-E14

**Name not found**

```
error[MBS-E14]: cannot find `colour` in this scope
  --> a.mbs:9:20
   |
 9 |     return colour * tint
   |            ^^^^^^ not found
   |
   = help: a field with a similar name exists: `color`
   = more: docs/shader_errors.md#mbs-e14
```

---

## MBS-E15

**Missing or wrong entry point**

```
error[MBS-E15]: `Varying` has no `out:"position"` field
 --> sprite.mbs:7:12
  |
7 | Varying :: struct {
  |            ^^^^^^ which field is the position?
  |
  = note: the vertex stage must write the clip-space position, and one field says so with the tag `out:"position"`
  = help: add `position: [4]f32 `out:"position"``
  = more: docs/shader_errors.md#mbs-e15
```

**Why.** A shader needs two procedures with fixed names and shapes (`shader_language.md`, section 4):

```odin
vertex_main   :: proc(input: Vertex_In) -> Varying { ... }
fragment_main :: proc(v: Varying) -> [4]f32 { ... }
```

mbsc reports, each with its own message:

- `vertex_main` or `fragment_main` is missing, or is declared as something that isn't a procedure.
- `vertex_main` doesn't take exactly one parameter and return exactly one value.
- `fragment_main` doesn't take the struct `vertex_main` returns, or doesn't return `[4]f32`.
- a field of the vertex input has no `attr:` tag.
- the vertex output has no `out:"position"` field, or its position isn't `[4]f32`.

A struct name that doesn't exist is `MBS-E14`; a tag with a value the engine doesn't know is `MBS-E24`.

**Fix.** Make the declaration match the shape above.

---

## MBS-E16

**Odin feature not available in shaders**

```
error[MBS-E16]: `switch` is not available in shaders
  --> sprite.mbs:22:5
   |
22 |     switch mode {
   |     ^^^^^^ shaders use `if` chains
   |
   = note: a shader is a small Odin subset: no pointers, slices, strings, maps, `switch`, `defer` or `import`
   = help: use `if mode == 0 { ... } else if mode == 1 { ... }`
   = more: docs/shader_errors.md#mbs-e16
```

**Why.** Shaders run on a GPU with no memory allocator and, on the 3DS, no jump tables. The subset is what all three
targets can express. It is listed in `shader_language.md`, section 2.

**What is checked.** Odin's parser accepts all of Odin, so mbsc then looks for anything outside the subset and
reports each one, not only the first:

| Not available | Instead |
|---|---|
| `import`, `foreign` | one file; the built-in functions need no import |
| `defer`, `using`, `context`, labels, `#` directives, `break`, `continue`, `#unroll` | leave it out; guard the code with an `if` |
| `switch` | an `if` / `else if` chain |
| `for` other than `for i in a..<b` or `a..=b` | a constant range, or an integer uniform on the 3DS |
| pointers, `&`, slices, dynamic arrays, maps, strings, `rune`, `any`, `typeid`, `rawptr` | values and fixed arrays |
| `new`, `make`, `delete`, `free`, `append` | a fixed array |
| `enum`, `union`, `bit_set`, `bit_field` types | constants, a struct, `bool` |
| `a if c else b`, `or_else`, `or_return`, `cast`, `transmute`, `auto_cast`, `x.(T)` | an `if` statement; write `f32(x)` |
| operators `% & \| ~ << >> &~ in not_in` | `mod(a, b)` or `fmod(a, b)`; integers have no bit arithmetic |
| several names in one declaration or assignment | one per line |
| a procedure inside a procedure, generic or variadic procedures, `where`, a calling convention | top-level procedures with fixed types |
| more than one return value | return a struct, or an array like `[2]f32` |
| a struct with parameters, `#packed`, `#align` or `using` fields | a plain struct |

**Fix.** Rewrite with the allowed constructs.

---

## MBS-E17

**Recursion**

```
error[MBS-E17]: `fade` calls itself
  --> fx.mbs:8:12
   |
 8 |     return fade(x - 1.0)
   |            ^^^^ recursive call
   |
   = note: mbsc inlines every procedure, and the GPUs have no call stack for it to use otherwise
   = help: use a `for` loop over a constant range
   = more: docs/shader_errors.md#mbs-e17
```

**Why.** Procedures are inlined into their callers. A cycle never finishes inlining, and the targets have no stack.
A cycle through several procedures is reported too, listing each call in the loop.

---

## MBS-E18

**Unknown engine uniform field**

```
error[MBS-E18]: the engine's `render` block has no field `tintt`
  --> sprite.mbs:12:21
   |
12 |     output.color = input.color * render.tintt
   |                                          ^^^^^ not a field of `render`
   |
   = note: `render` has: model, tint, uv_rectangle, alpha_cutoff
   = help: did you mean `tint`?
   = more: docs/shader_errors.md#mbs-e18
```

**Why.** The engine fills `frame` and `render` itself, so a shader can only declare fields the engine really provides.
A uniform of your own goes in a separate `@(uniform) name: type` declaration. mbsc reports a field the engine
doesn't have where it is declared; a field the engine has but with the wrong type is `MBS-E13`.

---

## MBS-E19

**More than 3 textures in a 3DS fragment shader**

```
error[MBS-E19]: this fragment shader reads 4 textures; the 3DS has 3 texture units
  --> terrain.mbs:9:1
   |
 9 | @(texture = 3) detail: Texture2D
   | ^^^^^^^^^^^^^^ slot 3 doesn't exist on this target
   |
   = note: building for `3ds`: slots 0, 1 and 2 are the texture units
   = help: bake `detail` into `albedo` offline (the sprite packer can do it)
   = help: or give the 3DS its own shader without it: `when TARGET != .PICA200 { ... }`
   = more: docs/shader_errors.md#mbs-e19
```

**Why.** The PICA200 has three texture units and a combiner can read only those. PC and Vita have many more, so
the same shader builds for them.

**Fix.** Use fewer textures, or combine two into one before the game loads them.

---

## MBS-E20

**Texture coordinate is not a plain texcoord varying**

```
error[MBS-E20]: this texture coordinate is computed per pixel
  --> water.mbs:27:27
   |
27 |     color := sample(tex, v.uv + render.scroll)
   |                          ^^^^^^^^^^^^^^^^^^^^ not a texcoord straight from the vertex stage
   |
   = note: on the 3DS a texture unit reads one of the interpolated texcoord outputs and nothing else
   = help: add the scroll in the vertex stage: `output.uv = input.uv + render.scroll`
   = more: docs/shader_errors.md#mbs-e20
```

**Why.** The 3DS has no pixel shader to calculate a coordinate. The coordinate has to arrive already worked out,
as a `texcoord0`, `texcoord1` or `texcoord2` output of the vertex stage. PC and Vita calculate it per pixel.

**Fix.** Do the arithmetic in the vertex stage, and pass the result in a tagged `texcoord` field.

---

## MBS-E21

**Two different constants needed in one combiner stage**

```
error[MBS-E21]: this combiner stage needs two different constant colours
  --> flash.mbs:30:12
   |
30 |     return sample(tex, v.uv) * render.tint + render.flash
   |            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ `tint` and `flash` both need the stage's constant
   |
   = note: each stage has one constant colour register
   = help: split it into two stages: `c := sample(tex, v.uv) * render.tint` then `return c + render.flash`
   = help: or combine `tint` and `flash` into one uniform
   = more: docs/shader_errors.md#mbs-e21
```

**Why.** A combiner stage can take a constant as an input, but there is one constant colour per stage, not one
per input. A shader that uses two different constants in one stage doesn't fit it.

**Fix.** Put the constants in separate stages, or merge them into one uniform.

---

## MBS-E22

**Syntax error**

```
error[MBS-E22]: expected '}' after field list, got ':'
 --> sprite.mbs:4:4
  |
4 | f :: proc() {
  |    ^ Odin's parser stopped here
  |
  = note: mbsc reads a shader with Odin's own parser, and this is the message the parser gives
  = more: docs/shader_errors.md#mbs-e22
```

**Why.** A shader is Odin text, so it has to be valid Odin first. The message is Odin's own. It often points at the
line *after* the real mistake, because the parser only notices once it can't go on: a missing `}` or `)` shows up
at the next declaration.

**Fix.** Look at the line the message names and the one before it. A `.mbs` file has no `package` line; mbsc adds
it.

---

## MBS-E23

**`when` condition can't be decided**

```
error[MBS-E23]: `.PICA2000` is not a target
  --> fx.mbs:20:16
   |
20 | when TARGET == .PICA2000 {
   |                ^^^^^^^^^ unknown target
   |
   = note: `TARGET` is one of `.PC`, `.VITA` or `.PICA200`
   = help: did you mean `.PICA200`?
   = more: docs/shader_errors.md#mbs-e23
```

**Why.** A `when` is settled before the shader is compiled, so only the chosen branch is checked and built. Its
condition can use `TARGET`, `==`, `!=`, `&&`, `||`, `!` and parentheses, with `.PC`, `.VITA` and `.PICA200`.
Anything that depends on a value at run time (a uniform, a call) can't be decided then.

**Fix.** Test `TARGET`. For a decision at run time use an ordinary `if`.

---

## MBS-E24

**Unknown or misplaced attribute or tag**

```
error[MBS-E24]: `texcord` is not a known attribute
 --> sprite.mbs:3:2
  |
3 |     uv:       [2]f32 `attr:"texcord"`,
  |     ^^^^^^^^^^^^^^^^ unknown value in `attr:"texcord"`
  |
  = note: the attributes a shader can use are: position, texcoord, color
  = help: did you mean `texcoord`?
  = more: docs/shader_errors.md#mbs-e24
```

**Why.** Attributes (`@(uniform)`, `@(texture = N)`) and field tags (`attr:"..."`, `out:"..."`) are how a shader says
what a name is bound to, so each has a fixed set of words. mbsc reports:

- an attribute that isn't `uniform` or `texture`, a texture with no slot or a slot that isn't a whole number, a
  uniform block that isn't `.FRAME` or `.RENDER`, an attribute on a `::` declaration;
- a variable at the top level that is neither a uniform nor a texture (a shader has no global variables), or a
  uniform given a value (the game sets uniforms);
- a field tag that isn't of the form `key:"value"`;
- an `attr:` value that isn't an attribute of the mesh, or an `out:` value a target can't carry;
- an `out:` tag on the vertex input or an `attr:` tag on the vertex output.

**Fix.** Use one of the names the message lists.

---

## MBS-E25

**Declared twice**

```
error[MBS-E25]: texture slot 0 is used twice
  --> sprite.mbs:11:16
   |
11 | @(texture = 0) b: Texture2D
   |                ^^^^^^^^^^^^ `a` and `b` share slot 0
   |
   = note: a slot is one texture unit, and it holds one texture
   = help: give each texture its own slot
   = more: docs/shader_errors.md#mbs-e25
```

**Why.** Each of these must be unique, and a second use would silently replace the first:

- a name at the top level (including the names built into the language, `TARGET`, `Target` and `Texture2D`);
- the engine's `.FRAME` or `.RENDER` block;
- a texture slot;
- an `out:` name in the vertex output (two fields writing `texcoord0`, or two positions).

**Fix.** Rename, merge, or remove one.

A local variable declared twice in the same scope is also this error.

---

## MBS-E26

**Fragment-only built-in used in the vertex stage**

```
error[MBS-E26]: `discard` is only available in the fragment stage
  --> a.mbs:14:5
   |
14 |     discard()
   |     ^^^^^^^^^ not in the vertex stage
   |
   = note: it is used in `vertex_main`, and the vertex stage has no pixel to discard
   = help: do this in `fragment_main`, or pass the value through a varying
   = more: docs/shader_errors.md#mbs-e26
```

**Why.** `discard`, `sample_bias`, `sample_grad`, `ddx`, `ddy`, `fwidth` and `dot3_signed` work on pixels, so
they only exist in `fragment_main`. The check follows calls: a helper that uses one is an error when `vertex_main`
reaches it, and the message says which procedure was called from the vertex stage. A helper used only by
`fragment_main` may use all of them.

**Fix.** Move the work to the fragment stage.

---

## MBS-E27

**Assignment to something read-only**

```
error[MBS-E27]: cannot assign to `input`
  --> a.mbs:10:5
   |
10 |     input = other
   |     ^^^^^ parameters can't be assigned to
   |
   = help: copy it into a local variable first: `v := input`
   = more: docs/shader_errors.md#mbs-e27
```

**Why.** Only local variables can be assigned to (including their fields and swizzles: `output.uv.x = 1.0`).
Parameters, uniforms (and their fields), textures, constants declared with `::`, and call results can't.
A swizzle that names a component twice on the left (`v.xx = ...`) is also this error, since both would be written.

**Fix.** Assign to a local copy.

---

## MBS-E28

**The PC backend can't write this**

```
error[MBS-E28]: `five` returns an array, which the PC backend can't write
  --> a.mbs:23:1
   |
23 | five :: proc() -> [5]f32 {
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^ returns an array
   |
   = note: HLSL has no array result, so the generated shader would not compile
   = help: return a struct that holds the values, or fill an array the caller declared
   = more: docs/shader_errors.md#mbs-e28
```

**Why.** Everything in the language is meant to build on every target, but a few things can't be written as HLSL.
mbsc says so with a position instead of printing HLSL that d3dcompiler refuses. The cases:

- a procedure that returns an array;
- an array written out as an argument (`f([3]f32{...})`; HLSL accepts an array literal only as the start of a variable);
- a procedure that samples a texture and runs in both stages (HLSL needs a mip level in the vertex stage and
  derivatives in the fragment stage, so one copy can't serve both);
- a game uniform whose type is a struct written inline (`@(uniform) light: struct { ... }`; the game sets a struct
  uniform by naming its fields, and the targets need the struct's name to lay it out). This one applies to every target.

**Fix.** Return a struct, put the array in a variable first, write one procedure for each stage, or name the struct.
