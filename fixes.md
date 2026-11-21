# Fixes.md

# Issues / Pain Points
These are issues / Pain Points I've come across while using Matchbox and should / need to be addressed

Legend
[x] Done
[c] Not done but will have claude do
[-] WIP or Ongoing
[?] Issue but there is a workaround

## See Comment above CreateWindowExW in init proc

## Assets folder + target folders need to be included in the repository upstream, just not contents of target folders

## [c] texutres are loaded, they aren't created. Will need to rename the procs to they reflect that. The style guide in the main branch has the specific rules for this
Will have claude do this change since it's just nameing refactoring

## [-] Update comments for Matchbox API to give rundown as to what they do

## [x] create_camera_2d(...) should have default of window height if no arugment is provided

## Center is (0, 0, 0) which makes positioning things tedious -- need a way to position them more seamlessly. Might have to use procs like Citro does it but would like to avoid if possible.

## when no .meta is present, the code should make assumptions on how the sprite sheet works

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

# Nice to haves

These are things that would be nice for Matchbox to have but are not a requirement

## [x] Add parallax scrolling to matchbox (see flappy-clone for implementation details)

