# Matchbox
---
**Highly Experimental**

Matchbox is a **WIP** game framework for making video games; built on top of the `no_gfx_api` (https://github.com/LeonardoTemperanza/no_gfx_api)

**Currenlt status: Currenlty rewriting. Due to the heady use of AI in the 3D rewrite, it became unruly and stopped making sense**

## What is Matchbox
`Matchbox` is a personal project of mine to make a framework for making video games / graphical applications.

## Technology Stack for Matchbox
|Name|Descirption|Repo|
|----      |-----------|----|
|no_gfx_api|The underlying graphics layer|https://github.com/LeonardoTemperanza/no_gfx_api|
|SDL3      |The window platform layer. the version is whatever the current in Odin is.    | In vendor
|stb       |The font sytem| In vendor

**IMPORTANT** Matchbox comes with its own copy of `no_gfx_api` as to avoid any breaking changes.

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

### Linux
Build `SDL3` on linux (Min. 3.4.2)
call `make -C {path to Odin/vendor/stb/src}` to build stb on linux

### Windows
Just build the application as normal and make sure that the SDL3 Bindings are in the same directory as the executable

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
