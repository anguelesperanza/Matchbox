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

# What needs implementation

## Milestone 2: 2D
This is a list of immediate needs to implement before Milestone 2: 2D is marked as compeleted (unless marked as [?])

[-] `Logging` - This works on PC but there's no logging implemented on the 3DS yet
  - Basic print() implemented but may need to improve (or can leave it it's good enough)

[x]`Input - Joystics and Triggers` - While the face buttons are all implemented for both PC and 3DS,
the joystics movement values are not yet captured by Matchbox for either the PC or 3DS.
   - Specifically on PC the triggers are not yet captured. The 3DS does not have triggers and will need that
     call stubbed out
   - How a game choses to interpret input values like joysticks and triggers -- where they are a range of 0 to 1,
     is up to the game. Matchbox simple provided that value to be used

[-] Sprites
  - Matchbox has sprite and can render them to PC and 3DS using the API however certain aspects of it are missng
  - Need to add rotation
  - Need to add scaling
  - Need to add transparency support

[ ] Lighting + Shadows
  - I want matchbox to have 2D lighting support

[?] Custom Shading Language
  - This is a big one and might not get done but looking into feasability
  - Not requirement at this stage of development
