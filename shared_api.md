# Shared API

This file aims to document how the shared api works, it's current state, and what's in progress

this document is broken up into 3 sections
- Shared -- Procedues / Structs / Enums / ect that are not backend specific
- Backend -- Anything backend specific
- WIP -- Features still in the works but not completed yet

`Status`: WIP - Everything just started

## WIP

`Projection` -- PC backend does not have projections yet, this mean rendering a triangle with a shape is not possible
as this time, but render with points directly. Will be fixed once PC backend can do projection
  - will need something like this: `c3d.Mtx_OrthoTilt(&mbi.projection, 0, 400, 240, 0, 0, 1, true)` however adding
  now will break feature parity

`Input` -- while input works now; it's not great. PC has it's own bindings and so does o3dx,
but that means that pressing N in the emulator 


## Shared
`shapes.odin` - Only the `render_triangle` call is backend specific



## demo.odin

The demo file - demo.odin - is an example of how the shared api will work

## entry_point_arm32

O3DX is compiled using the dev kit pro toolchain. This tool chain requires a specific entry point.

That entry point is `entry_point_arm32.odin`, which creates an export procedure that is called by main.c 

## init

The `matchbox.init(...)` proc behaves differenlty dependings on the platform, however the arguments remain the same

On windows, the title, width, height of the window are decided based on the arguments passed

On the 3DS these values are fixed as the new 3DS LL/XL has a fixed screensize
