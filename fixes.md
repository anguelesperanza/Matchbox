# Fixes.md

# Issues / Pain Points
These are issues / Pain Points I've come across while using Matchbox and should / need to be addressed

Legend
[x] Done
[c] Not done but will have claude do
[-] WIP or Ongoing
[?] Issue but there is a workaround

## See Comment above CreateWindowExW in init proc

## [x] Assets folder + target folders need to be included in the repository upstream, just not contents of target folders

## [x] texutres are loaded, they aren't created. Will need to rename the procs to they reflect that. The style guide in the main branch has the specific rules for this

Will have claude do this change since it's just nameing refactoring

## [-] Update comments for Matchbox API to give rundown as to what they do

## [x] create_camera_2d(...) should have default of window height if no arugment is provided

## [x] Center is (0, 0, 0) which makes positioning things tedious -- need a way to position them more seamlessly. Might have to use procs like Citro does it but would like to avoid if possible.

Done: `calculate_visible_rectangle` and `calculate_anchor_position` (and the camera and bottom-screen versions) place things from the corners and edges of what is visible.

## [x] when no .meta is present, the code should make assumptions on how the sprite sheet works

Right now, if we try and animate a sprite with no .meta file, it doesnt' work. I need a way for the code to make a "best guess"
as to what that information is and use that instead when there is no .meta file present.

If a .meta file is present, it will use that over this best guess. We need this as it's not always easy to make a .meta file with
the current way the asset pipeline + sheetpack work (see convern below)

## [?] sheetpack needs work and/or asset paths need rework

Sheetpack looks at a folder and generates a .meta on the images there.
This works small scale, when only the image assets for the spritesheet are present, but fails when there's different
sized assets in the folder.

sheetpack needs to be updated to work with just a single file as an argument as well. So it can target either the entire folder,
or a specific file in that folder.

The Asset path doesn't check nested folders once the main asset folers (images, audio) are hit.
This creates the problem with sheet listed above.

The workaround: provide full file path starting from root asset folder where the assets are stored
example: assets/images/sprites/meme.png => mb.create_sprite("sprites/meme.png") <= path starts from inside images

## [x] Add velocity to sprite struct
## [x] Add jump force to sprite struct
## Add is_alive check to sprite struct

## [x] Parallax struct

Make a parallax struct that contains a `[dynamic]Sprite` to make some of the values like scale consistant across other create_* procs. May not do this though as it's not a crazy thing.

## [x] Review cooldown.odin file. It's awkward to use and needs rework

Done: `Cooldown` is delta-driven with `start_cooldown`, `update_cooldown`, `stop_cooldown`, `is_cooldown_finished`, `is_cooldown_running` and `calculate_cooldown_progress`.

## create_sprite calls create_texture under the hood
Right now, creating a sprite requires a texture. Really, calling create_sprite should create the texture it needs. Will look into feasibility of this

## create_mesh should create a mesh. If no values are provided, it should use defaults instead
## [x] mesh_cube(...) and related names should be changed to reflect that they are procedures and not something else

Done: `create_cube_geometry`, `create_quad_geometry`, `create_triangle_geometry`, `create_circle_geometry`, `create_plane_geometry`, `create_sphere_geometry` and `create_cylinder_geometry`. They build vertices and indices on the CPU; `create_mesh` and `create_lit_mesh` upload them.

## FPS set -> Have a proc to set the max FPS limit
## VSYNC toggle -> Have a proc to toggle vsync on and off
## [x] Add remaining keyboard keys to input on pc

Done: the keypad (`NUMPAD_0`..`NUMPAD_9`, `MULTIPLY`, `ADD`, `SEPARATOR`, `SUBTRACT`, `DECIMAL`, `DIVIDE`, `KEYPAD_ENTER`), `F1`..`F12`, `NUMLOCK`, `SCROLL_LOCK` and the punctuation keys (`SEMICOLON`, `EQUALS`, `COMMA`, `MINUS`, `PERIOD`, `SLASH`, `GRAVE`, `LEFT_BRACKET`, `BACKSLASH`, `RIGHT_BRACKET`, `APOSTROPHE`), with `is_key_repeated` apart from `is_key_pressed`. The handheld `Key` has the same names.

## Add logging to Matchbox (need to check if runtime for 3DS and Vita can do this as original runtime support could not)
## PSX Shaders need work -- logs of geometry flickering happening
## custom shaders (ones added by a user and not loaded into the game) need 3DS and Vita Backend support
## Find an api way to handle creating logs to avoid using `when` keyboard in standalone projects

# Nice to haves

These are things that would be nice for Matchbox to have but are not a requirement

## [x] Add parallax scrolling to matchbox (see flappy-clone for implementation details)

## Add move procs to sprites as parallax has one and now the rest of the sprites api feels out of date

