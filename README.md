# Matchbox
---
**Highly Experimental**

Matchbox is a **WIP** game framework for making video games; built on SDL3, using its GPU API for rendering.

**Currenlt status: WIP for sure; I update this add needed. Only 2D support for now but 3D support planned**

## What is Matchbox
`Matchbox` is a personal project of mine to make a framework for making video games / graphical applications.

## Technology Stack for Matchbox
|Name|Descirption|Repo|
|----      |-----------|----|
|SDL3      |The window platform layer *and* the graphics layer, through its GPU API. The version is whatever the current one in Odin is.| In vendor
|stb       |The font sytem| In vendor

SDL3 is the only thing Matchbox needs at runtime. It used to render through a
vendored copy of `no_gfx_api`, which required `VK_EXT_shader_object` -- an
extension Intel's Vulkan driver does not provide, so an Arc B580 could not start
a game at all. SDL3's GPU API asks for nothing of the kind, and brings a D3D12
fallback with it.

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
Copy the `matchbox` folder to your project directory and import it

```odin
package game

import "matchbox"

main :: proc() {
	matchbox.init("My Game", 1280, 720)

	player := matchbox.create_sprite(#load("player.png"))

	for matchbox.is_running() {
		matchbox.poll_events()

		if matchbox.is_key_held(.D) {
			player.position.x += 200 * matchbox.delta_time()
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

### Gamepads
Up to four controllers, addressed by a slot that behaves like a player number.
The first pad to connect is 0, and a pad that is unplugged frees its slot for
the next one. Nothing has to be set up -- plugging one in mid-game is handled.

```odin
if matchbox.is_gamepad_connected(0) {
	move := matchbox.get_gamepad_stick(0, .LEFT)
	player.position += move * speed * matchbox.delta_time()

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

## Font
The default font for Matchbox is called Silver and can be found here: https://poppyworks.itch.io/silver

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
