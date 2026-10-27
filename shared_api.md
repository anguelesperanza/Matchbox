# Shared API

This file aims to document how the shared api works, it's current state, and what's in progress

`Status`: WIP - Everything just started

## demo.odin

The demo file - demo.odin - is an example of how the shared api will work


## init

The `matchbox.init(...)` proc behaves differenlty dependings on the platform, however the arguments remain the same

On windows, the title, width, height of the window are decided based on the arguments passed

On the 3DS these values are fixed as the new 3DS LL/XL has a fixed screensize
