# The intermediate form of mbsc

`mbsc` turns a shader that passed every check into a typed tree, and the backends (HLSL, Cg, PICA200 assembly)
read that tree instead of the source. This page says what the tree is, what it no longer has compared with the
source, and how to print it.

```
mbsc shader.mbs -target:pc --dump-ir
```

prints the tree for one target. A shader with errors prints the errors, as usual, and no tree.

## What changes between the source and the tree

| In the source | In the tree |
|---|---|
| `when TARGET == .PICA200 { a } else { b }` | only the branch for this target, as a block |
| `NAME :: 2.0` used in an expression | the value, `2.0`, written where the name was |
| `a += b` | `a = a + b` |
| `(a + b)`, unary `+a` | `a + b`, `a`: parentheses and unary plus are gone |
| `x: T` | a declaration with no value, which starts as zero |
| `T{}` | zero of `T` |
| `Light{strength = 2.0}` | a literal with every field, in declaration order; a field left out is zero |
| `v.bgr`, `v.a` | a swizzle by component number: `.zyx`, `.w` |
| `f32(x)`, `i32(x)`, `u32(x)` | a conversion node |
| a procedure no entry point can reach | not there |
| a name that two variables share (shadowing) | each variable has a number that is unique in its procedure |

Every expression carries its type. Procedures are listed with the ones they call first, so a backend that needs a
function before its use (HLSL does) can write them in order. The checker has already rejected recursion.

## The nodes

Expressions: float, integer and bool literals; `zero`; a variable, uniform or texture; a unary or binary
operation; a swizzle; a struct field; an index; a conversion; a construction of a vector, array, struct or matrix
from all of its parts; a call to a built-in; a call to a procedure of the shader.

Statements: declare a variable, assign, `if` with an optional `else`, `for` over a range (the end is included
only for `..=`), `return`, a call whose value is not used (`discard()`), and a block.

A matrix literal keeps its numbers in the order they were written.

## The text form

```
target pc

struct Varying
  position: [4]f32  out:position
  ...

uniform render: the engine's render block
  model: matrix[4, 4]f32
  ...
texture tex: slot 0

proc vertex_main(input#0: Vertex_In) -> Varying  [vertex stage]
  var output#1: Varying = zero
  output#1.position = (frame.view_projection * world#2):[4]f32
  return output#1
```

- `name#N` is a variable and its number; the number is what tells two `x` apart.
- A result that isn't obvious from its parts is followed by its type: `(a * b):[4]f32`, `sample(tex, uv):[4]f32`.
  Literals, variables, fields and indexes are not.
- `const` is a variable declared with `::` inside a procedure; `var` is one declared with `:=` or `: T`.

`tools/mbsc/testdata/mesh_pc.ir.txt` is the tree of `tools/mbsc/testdata/mesh.mbs`, and a test checks that they
still agree. Change the language or the lowering on purpose, and regenerate it with `--dump-ir`.
