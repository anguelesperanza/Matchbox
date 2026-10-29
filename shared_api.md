# Matchbox API Development Status

This document keeps track of the current status of the Matchbox API, it's procedures that do things, and how
the api is currenlty split up -- this will certaintly change as changes to the API are made.


# Approach to API Design

the `demo.odin` file is designed first. The procedure calls, game loop shape, etc, are all added there first.
Even if there is no implementation for a procedure yet.

The backends are then designed around that and procedures are tweaked accordingly when and where it makes sense.

Procedures that aren't properly implmemented in a backend are marked as TODO and stubbed out so they don't fail at
compile time and runtime.

Procedures that won't be implemented in a backend are simple stubbed out and never used.

An example of this are the `is_key_*` procedures. The 3DS does not have a keyboard so there is nothing to map here.
In order to not break the API or add any confusing input logic; the `is_key_*` procs are all return false on the 3DS.

# Demo.odin

The `demo.odin` file is the example odin file that uses the matchbox api.

Running `odin build .` / `odin run .` will generate an exe using that file for PC
Running `build.bat` will generate a .3dx and .elf file using that file for the 3DS

# What needs implementation

There are a few things that need to be implemented properly before I can call them.

`Logging` - This works on PC but there's no logging implemented on the 3DS yet

`Input - Joystics and Triggers` - While the face buttons are all implemented for both PC and 3DS,
the joystics movement values are not yet captured by Matchbox for either the PC or 3DS.

Specifically on PC the triggers are not yet captured. The 3DS does not have triggers and will need that
call stubbed out

How a game choses to interpret input values like joysticks and triggers -- where they are a range of 0 to 1,
is up to the game. Matchbox simple provided that value to be used
