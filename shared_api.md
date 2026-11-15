# Matchbox API Development Status

This document keeps track of the current status of the Matchbox API, it's procedures that do things, and how
the api is currenlty split up -- this will certaintly change as changes to the API are made.

For references on the actual procedure calls / API and how they work and Platform specific details -- see cheatsheet.md

Key:
[ ] => Aware of but not started on

[?] => May need to implement; unsure if will or if actually needed

[-] => WIP, started on but not complete

[x] => Completed; no immediate work left

# Approach to API Design

the `demo.odin` file is designed first. The procedure calls, game loop shape, etc, are all added there first.
Even if there is no implementation for a procedure yet.

The backends are then designed around that and procedures are tweaked accordingly when and where it makes sense.

Procedures that aren't properly implmemented in a backend are marked as TODO and stubbed out so they don't fail at
compile time and runtime.

Procedures that won't be implemented in a backend are stubbed out and never used.

An example of this are the `is_key_*` procedures. The 3DS does not have a keyboard so there is nothing to map here.
In order to not break the API or add any confusing input logic; the `is_key_*` procs are all return false on the 3DS.

# Demo.odin

The `demo.odin` file is the example odin file that uses the matchbox api.

Running `odin build .` / `odin run .` will generate an exe using that file for PC

Running `build.bat` will generate a .3dx and .elf file using that file for the 3DS

# Rendering approach

In matchbox, everything in considered 3D and things are placed in world space -- this included 2D as well.

Originally, this full-rewrite had a dedicated 2D rendering path and 3D would be built to work along side it,
however something I hadn't taken into account properly was screen size.

PC, 3ds and Vita all have different screen sizes, so PC and Vita would need to at least match the smallest size.

This means games would look fine on the 3DS, but would letterbox on PC and Vita. I did not want this as this would be
a messey to handle.

The new approach is to make everything 3D and place everything in a 3D world -- results are not far enough along yet
to determine if this is the correct approach or not. 
