# Matchbox
---

STATUS: **ARCHIVED**

Due to my complete lack of understanding of Graphics Programming and that this code base is AI Generated over the
course of a few months; Matchbox is currenlty archived.

I've encounted issues I don't quite know how to solve due to never learning a graphics api, and while I could
weed my way through it with Claude; which is what I've done this far; I've started noticing gaps appearing
randomly. Fixes to those gaps, create more gaps and the cycle just repeats.

The point of matchbox was to add to it; as I needed more features to make games. At somepoint though, I lost
the plot and just started adding things to it. 

I might spend some time learning a graphics api on my own but it's not a subject I'm super interested in
in the first place. I like the idea of graphics programming, but I think the API implementations are hard to follow
and learning resources are either out dated, or hard to follow.

The inner matchbox folder -> This contains the api implementation; should work just fine.
eko should work just fine as well.
tether should work just fine, though that needs a bunch of polish it doesn't have so it's sort of a pain to use

The examples may not work. They should have been kept updated as changes to the api are made, but they may point
resources not in the repo as claude got hooked on importing resources from other projects 

It uses SDL 3 and SDL_GPU.

Matchbox follows very specific style guide for how I like to program. This means enums, struct, proc names are
all formatted in very specific ways. You can find the specific style guide in `CLAUDE.md`.

Ideally, this should make the repo more on the human readable side of AI generated code since it follows my
personal preference of programing, and not whatever way Claude decided things should look.

Everything in this repo is left as is, and wasn't touched up for the public switch.

**I don't recommend using this for projects.** I've made this repo public so others can take a look at how
things in matchbox are implemented for their own projects.

Maybe I'll come back to this if I learn more graphics programming, but for now, the project remains archived.

--- 

Matchbox is a **WIP** game framework for making video games; built on SDL3, using its GPU API for rendering.

**Currenlt status: WIP for sure; I update this add needed. Only 2D support for now but 3D support planned**

## What is Matchbox
`Matchbox` is a personal project of mine to make a framework for making video games / graphical applications.

It is a **full game framework**, not a rendering layer: drawing, input, UI,
levels, physics and audio. That was the original intent, then it was cut back to
rendering and input on the reasoning that everything else could be its own
project, and on **2026-09-17** it came back for good -- with the pieces that had
gone off on their own brought back in. See [Packages](#packages).

## Packages

Matchbox is one repository holding four Odin packages. A game imports the ones
it needs and pays for nothing else:

| Import | What it is | Needs |
| --- | --- | --- |
| `matchbox/matchbox` | drawing, input, files, UI, the frame loop | SDL3, stb |
| `matchbox/level` | the level format Stargate's editor reads and writes | `matchbox` |
| `matchbox/tether` | physics: worlds, box and capsule bodies, rays | `vendor:box3d` |
| `matchbox/eko` | audio: an engine, players, 2D and 3D listeners | `vendor:miniaudio` |

- **Four siblings, no nesting.** `level` sat at `matchbox/level/` until
  2026-09-18 and moved up beside the others. It reaches Matchbox as
  `../matchbox`, which is the same directory a game reaches as
  `matchbox/matchbox` -- one package, not two, because Odin identifies a package
  by the full path a relative import lands on. Two paths really would be two
  packages, with two `mbi`s, which is why they all live in one repository.
- **None of them is folded into `package matchbox`**: that would link Box3D
  into a 2D game and miniaudio into a silent one, put a level loader in every
  game that draws a sprite, and give the package three globals where `mbi` is
  meant to be the only one. `tether` and `eko` also import nothing from
  Matchbox, so a game may use either without it.
- **`tether` and `eko` were separate repositories** until 2026-09-17 and are
  not any more. One repository is what lets `level` describe colliders that
  `tether` builds without either of them reaching outside it, and that kind of
  dependency only becomes more common as the framework fills in. `CLAUDE.md`
  has the full reasoning, and [tether.md](tether.md) is Tether's own guide.

## Technology Stack for Matchbox
|Name|Descirption|Repo|
|----      |-----------|----|
|SDL3      |The window platform layer *and* the graphics layer, through its GPU API. The version is whatever the current one in Odin is.| In vendor
|stb       |The font sytem| In vendor
|Box3D     |The physics solver `tether` wraps. Only linked by a game that imports `tether`.| In vendor
|miniaudio |The audio engine `eko` wraps. Only linked by a game that imports `eko`.| In vendor

SDL3 is the only thing `package matchbox` needs at runtime. It used to render
through a vendored copy of `no_gfx_api`, which required `VK_EXT_shader_object`
-- an extension Intel's Vulkan driver does not provide, so an Arc B580 could not
start a game at all. SDL3's GPU API asks for nothing of the kind, and brings a
D3D12 fallback with it.

On Windows Box3D's static library ships with the Odin compiler, so a game using
`tether` has no extra DLL to copy beside the one SDL3 already needs.

## Shaders
The built-in shaders live in `matchbox/shaders` as HLSL and are compiled into
the package, so a game does not build them. If you change one, run
`build_shaders.bat` (or `.sh`) at the repository root.

This needs `dxc` on PATH, which the Vulkan SDK provides -- it emits both the
SPIR-V that the Vulkan backend wants and the DXIL that D3D12 wants, from the
same source. Both are compiled and embedded, because SDL only offers a backend
whose shader format it was told about at startup; shipping SPIR-V alone would
mean Vulkan or nothing.

## How to use
Copy the folders you need into your project and import them. Most games want
`matchbox` alone; add `tether` for physics, `eko` for sound, and `level` if you
load levels built in Stargate's editor.

```odin
import mb  "matchbox/matchbox"
import lvl "matchbox/level"
import "matchbox/tether"
import "matchbox/eko"
```

The rest of this section is `matchbox` on its own:

```odin
package game

import "matchbox"

main :: proc() {
	matchbox.init("My Game", 1280, 720)

	player, err := matchbox.create_sprite(#load("player.png"))
	if err != nil do return

	for matchbox.is_running() {
		matchbox.poll_events()

		if matchbox.is_key_held(.D) {
			player.position.x += 200 * matchbox.get_delta_time()
		}

		matchbox.begin_drawing()
		matchbox.clear_background(matchbox.CORNFLOWER_BLUE)
		matchbox.draw_sprite(player)
		matchbox.end_drawing()
	}

	matchbox.destroy_sprite(&player)
	matchbox.cleanup()
}
```

### Errors
Anything that builds a thing which might not build hands back the thing *and* an
error, in the shape `core:os` uses:

```odin
sprite, err := matchbox.create_sprite(bytes)
if err != nil {
	// a picture stb could not read, or a texture the driver refused
}
```

The error is a union, so `err != nil` is the whole test. `Image_Error` means the
bytes were not a picture, `Gpu_Error` means the driver refused an allocation, and
`Argument_Error` means the size or the pixel count did not describe something
that could be made.

**What does *not* come back as an error is deliberate.** Drawing outside a pass,
`end_clip` without a `begin_clip`, using Matchbox before `init` -- those are bugs
in the calling code rather than conditions the world produced, and they stop the
program where the mistake is instead of being handed back as a value nobody
checks.

### State
Matchbox keeps everything it needs in one global, `matchbox.mbi`, so no state has
to be passed between procedures. It is grouped by subsystem -- `display`, `clock`,
`renderer`, `input`, `camera` -- and the fields games reach for most often are
promoted to the top, so `mbi.delta_time` and `mbi.width` work directly while the
internals stay behind `mbi.renderer`.

Read it wherever you like (`matchbox.mbi.camera.position = ...`), or take a local
alias if the qualified name gets tiresome:

```odin
mbi := &matchbox.mbi
```

One global means one window: Matchbox cannot run two independent instances in a
process.

### Buttons, text plates and a sprite cache
`button` draws, hovers and answers a click in one call. The size comes from the
Rectangle, so it is decided at the call site rather than by a constant:

```odin
if matchbox.button({position = {40, 40}, size = {180, 42},
                    color = {0.2, 0.2, 0.26, 1}, pivot = {0.5, 0.5}}, "Play") {
	start_game()
}
```

Pass a `Button_Style` with `align = .LEFT` for a label against the left edge,
which is what a stacked column of options wants.

`draw_text_plate` puts text on a dark plate cut to fit, for when it is drawn
over artwork and would otherwise disappear against something pale. It takes a
top-left rather than a baseline and returns the plate's size, so plates stack:

```odin
p := matchbox.draw_text_plate(font, name, {x, y})
matchbox.draw_text_plate(font, cost, {x, y + p.y + 4})
```

`Sprite_Cache` loads art on demand and keeps it under a key of any comparable
type. `limit` is how many may be resident -- zero for no limit, or one for a
single slot that evicts, which is what full-size art too big to keep around
wants. Eviction is least recently used, and a hit counts as a use.

```odin
cache := matchbox.create_sprite_cache(Card, limit = 1)
defer matchbox.destroy_sprite_cache(&cache)

if art := matchbox.sprite_cache_get(&cache, card, path); art != nil {
	sprite := art^          // a copy: position is yours, the cache keeps its own
	sprite.position = {x, y}
	matchbox.draw_sprite(sprite)
}
```

`button_confirm` is the Delete-then-"Sure?" pattern, for anything that cannot
be undone. It returns true only on the second press, and forgets after a few
seconds or if you click elsewhere:

```odin
if matchbox.button_confirm(&delete, rect, "Delete deck", "Sure?") {
	delete_deck(deck)
}
```

`hover_dwell` answers "has the pointer rested here long enough", which is what
keeps a preview from flickering its way across a grid as the mouse crosses it.
`hover_progress` gives 0 to 1 through the wait, for drawing it.

```odin
if matchbox.hover_dwell(&preview, card_rect) do draw_closeup(card)
```

Both keep their state in a struct you hold, one per widget, like `Text_Field`.

`Dropdown` is a box that opens into a list. It comes in two halves, because
drawing here is immediate and an open list has to appear over things drawn
after it:

```odin
// early: the closed box, and all of the input
if matchbox.dropdown(&filter, box, options) do refilter()

... the rest of the screen ...

// late: the open list, over the top
matchbox.dropdown_overlay(&filter, options)
```

While a list is open it calls `capture_mouse`, and `button`, `button_confirm`,
`hover_dwell` and `Text_Field` all check `is_mouse_captured` for you -- so a
button under an open list neither lights up nor answers a click. Anything
hit-testing the mouse by hand should ask as well:

```odin
over := matchbox.is_mouse_over_rect(cell) && !matchbox.is_mouse_captured()
```

That only reaches widgets drawn *after* the dropdown, so draw it before the
things it covers.

`is_point_in_rect` is the plain geometric test the rest are built on, for
anything hit-testing something that is not the mouse.

`examples/ui` shows all of these.

### Laying things out
`Layout` is a cursor down a column. Ask it for the next box and it has already
moved past, which saves threading a `y` through every call and adding heights
back by hand:

```odin
l := matchbox.create_layout({24, 24}, 190, 8)

if matchbox.button(matchbox.layout_next(&l, 40), "All cards") { ... }
if matchbox.button(matchbox.layout_next(&l, 40), "Owned")     { ... }
matchbox.layout_space(&l, 14)
matchbox.layout_text(&l, font, "v0.1")
```

Pass a width to `layout_next` for an item narrower than the column, centred in
it. It holds no state between frames — rebuild it each frame and there is
nothing to keep in sync.

`Grid` fits items into an area. The target size is a wish: it takes however
many columns fit at that width, then resizes the items so they fill the area
exactly, keeping the target's aspect ratio. The item size does not depend on
how many items there are, so a filtered list of three draws three normal cells
with space to the right rather than three enormous ones.

```odin
grid := matchbox.create_grid(area, {130, 180}, len(cards), 10)

for card, i in cards {
	cell := matchbox.grid_cell(grid, i)
	if matchbox.button(cell, card.name) do pick(card)
}
```

That is what keeps a layout picked on a large monitor from running off a small
one — narrow the window and the column count drops rather than the grid being
clipped. Rows are not capped to the area's height, because a grid taller than
its area is the scrolling case; `grid_height` gives the extent and `begin_clip`
confines it. `examples/layout` resizes live.

### Clipping
`begin_clip` confines drawing to a rectangle until the matching `end_clip`, so
a list can scroll inside a panel rather than running over what is below it.

```odin
matchbox.begin_clip(panel)
defer matchbox.end_clip()

for row, i in rows {
	matchbox.draw_text(font, row, x, y + f32(i) * 34 - scroll, matchbox.WHITE)
}
```

The rectangle is in the same coordinates you draw in -- the same `Rectangle`
you would hand `draw_rect` covers exactly the pixels that stay visible. Draw
every row and let the clip decide what shows; there is no need to work out
which ones are on screen.

This is the hardware scissor, so it cuts pixels rather than geometry: a glyph
half outside the box is drawn half rather than dropped. It is axis-aligned, and
a `Rectangle`'s `rotation` is ignored.

Clips nest and **intersect** -- a list clipped inside a panel cannot escape the
panel even if its own rectangle is larger. `examples/clipping` shows both.

### Gamepads
Up to four controllers, addressed by a slot that behaves like a player number.
The first pad to connect is 0, and a pad that is unplugged frees its slot for
the next one. Nothing has to be set up -- plugging one in mid-game is handled.

```odin
if matchbox.is_gamepad_connected(0) {
	move := matchbox.get_gamepad_stick(0, .LEFT)
	player.position += move * speed * matchbox.get_delta_time()

	if matchbox.is_gamepad_button_pressed(0, .SOUTH) {
		matchbox.set_gamepad_rumble(0, 0.6, 0.6, 200)
	}
}
```

`get_gamepad_stick` takes the deadzone out and rescales what is left, so a
stick starts from a standstill rather than jumping to a quarter speed the
moment it leaves the centre. The deadzone is radial rather than per-axis, which
is what stops a diagonal push snapping to one axis. `get_gamepad_axis` is the
same reading untreated, for when you want to do that yourself.

Y is positive downward on a stick, matching the screen coordinates everything
else draws in, so `position += stick` moves the way the stick is pushed.

Button names are SDL's, which are positional rather than branded: `.SOUTH` is
the bottom face button whether the pad in someone's hands calls it A, B or
Cross. `examples/gamepad` shows every button, stick and trigger at once.

### Getting SDL3 next to your program
`SDL3.dll` is not kept in this repository. Run `copy_sdl.bat` (or `copy_sdl.sh`)
once and it takes the one from your Odin installation, which is the same library
`vendor:sdl3`'s bindings were generated against:

```
copy_sdl.bat                 populate every example
copy_sdl.bat path\to\my\game put it beside your own build
```

It is worth understanding why rather than committing a copy and forgetting it.
This repository carried SDL **3.3.0** for months while the bindings were built
for **3.4.2**, so every build was reaching a two-minor-versions-old runtime
through newer headers, and nothing anywhere said so. Taking the library from the
Odin tree means the two cannot drift apart.

### Windows
Build as normal. `SDL3.dll` has to sit beside the executable -- see above.

### Linux
Build `SDL3` on linux (Min. 3.4.2)
call `make -C {path to Odin/vendor/stb/src}` to build stb on linux

Nothing needs copying: matchbox links `system:SDL3` on Linux, so the package
manager's copy is the one that matters. `copy_sdl.sh` says as much and exits.

### Android
Runs. The `ui` example draws on a phone -- GPU rendering on Vulkan, text, a
sprite loaded out of the apk, and buttons that answer a finger. Audio, gamepads
and pause/resume have not been exercised yet, and a game still has to cope with
being handed the whole screen rather than the window size it asked for, so treat
this as early rather than shipped.

The Android build lives *inside* the `matchbox` folder, so dropping matchbox into
a project brings it along -- there is nothing to copy separately and nothing at
the root of this repository to point at.

Set `ODIN_ANDROID_NDK` and `ODIN_ANDROID_SDK`, then run these once per copy of
matchbox -- the binaries they produce live in the folder, so a matchbox copied
into a new project needs them again:

```
matchbox\android.bat        cross-compiles stb for arm64 into matchbox\android\libs
matchbox\android_sdl.bat    downloads the arm64 libSDL3.so and SDL's Java classes
```

`android_sdl.bat` reads the version out of `vendor:sdl3` itself, so the library
matches the bindings for the same reason `copy_sdl.bat` exists.

One patch is needed in your Odin installation and is not optional. Odin turns
vendor:stb's path-named foreign imports into `-l:<absolute path>`, which lld
cannot resolve, so add an Android case to the `LIB` constant in
`vendor/stb/image`, `vendor/stb/truetype` and `vendor/stb/rect_pack`:

```odin
LIB :: (
         ""                          when ODIN_PLATFORM_SUBTARGET == .Android
    else "../lib/stb_image.lib"      when ODIN_OS == .Windows
    ...
```

That drops them through to the `system:` form already written below it. Desktop
builds are unaffected -- the gate is on the subtarget. The Android section of
`improvements.md` has the full account.

Then, from your own project -- matchbox builds whatever directory it was dropped
into, so there is no path to pass:

```
matchbox\android_apk.bat            builds the project, writes build\android\<name>.apk
matchbox\android_apk.bat install    and installs and launches it over adb
```

Give it a path to build something else. That is how this repository builds its
own examples, since they sit beside matchbox rather than above it:

```
matchbox\android_apk.bat examples\ui
matchbox\android_apk.bat examples\ui install
matchbox\android_apk.bat C:\path\to\game install
```

The package name defaults to `org.matchbox.<folder>`, which is fine for a debug
build and wrong for anything published -- set `MATCHBOX_ANDROID_PACKAGE` for
that. Everything in the project that is not source is packaged as an asset,
keeping its path, so `art\coin.png` is still read as `"art/coin.png"`; matchbox
itself is excluded, since its fonts and shaders are already `#load`-ed into the
binary.

Your own game needs no Android-specific code. SDL's own Java activity is the
entry point and looks for a symbol called `SDL_main`, and `matchbox/android.odin`
provides one that hands over to Odin's `_odin_entry_point`, so an ordinary
`main :: proc()` is all there is.

Three things to know when writing a game that will run there. Anything you ship
with the game must be read with `read_entire_file`, not `core:os`, because inside
an apk it is not a file; anything the player creates belongs under
`get_pref_path`, which is the one directory Android gives you; and the window
size you pass to `init` is a request the desktop honours and Android ignores,
so read `window_width` and `window_height` rather than assuming what you asked
for. The first two are already true on the desktop -- Android is just where
ignoring them stops working.

If nothing appears in `adb logcat`, check `adb shell getprop log.tag`. Some ROMs
ship it set to `S`, which silences the log completely; `adb shell setprop log.tag
V` fixes it until the next reboot.

## Font
The default font for Matchbox is called Adapa, and is embedded from
`matchbox/fonts/Adapa.ttf`. It is a pixel font drawn on a 13-pixel em, so use
**multiples of 13** -- 13, 26, 39, 52 -- and each of its design pixels lands on a
whole number of screen pixels. `DEFAULT_FONT_SIZE` is 26 for that reason.
`get_font` will bake any size you ask for, but a size between two multiples
gives you stems that are two pixels wide in places and three in others.

Adapa is a wider face than the Silver font it replaced: the same sentence set at
the same nominal size is about half again as long. A layout carried over from
before wants measuring rather than assuming.

The atlas holds printable ASCII, space through `~`. Anything outside that range
is skipped by `draw_text` and takes no room in `measure_text`.

If you want to load your own font; it needs to be a TTF. You can check the examples folder on how to load your own font.

# Inspiration
`Matchbox` is heavily inspired by `Raylib`. While I haven't used it in any great capacity. It felt felt great to use.
`Raylib` specifically rekindled my desire to make video games after being burnt out by `Unity` and `Godot`.

`XNA` was the other big inspiration in it. XNA just sorta stuck around rent free in my head.
Specifically, the water simulation video on Youtube I can no longer find, and the racing demo. And while `Matchbox` doesn't have much
to anything in common with `XNA` I feel the need to include it in the inspirations.

Two other inspirations are `Kha` and `HaxeFlixel`. While I haven't used Haxe in years, those were my first real big dives into game frameworks
after trying to moving away from game engines.

---
Raylib: https://www.raylib.com/
XNA: https://github.com/FNA-XNA/FNA (XNA itself is gone and has been for years, but is spritually succeeded b FNA)
Kha: https://github.com/Kode/Kha | https://kha.tech/
HaxeFlixel: https://haxeflixel.com/
