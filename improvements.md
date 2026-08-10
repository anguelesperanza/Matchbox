# Improvements

This file lists improvents I can make to Matchbox that I discovered while trying to create things.
These things might not have been finished and that's fine, what matters is that I discovered these
areas of improvement while trying to create them.

---

# Not Started

## Remove / Reduce AI Code

While I wrote a chunk of this, so did Claude. I'd like to
reduce the AI code as I make breaking api changes,
optimazations, etc

## Reduce System Usage

Basic Init Window example uses about 53mb of ram.
Need to compare to other frameworks to see if that's a lot?

## Procedure Groups

`destroy` procedure group so individual procedures do not need to be called


---

# Completed

## Redundant Input Flags

`Input.left_click_pressed` and `Input.pressing_right_click` said the same thing as
`mbi.input.mouse.buttons[.LEFT].pressed` and `[.RIGHT].pressing`, and only the button
array generalises to the middle button. Both are gone. Nothing read them -- `poll_events`
was the only code that touched them, and only ever to write.

## get_mouse_world_pos Only Works While Drawing

It applied the camera transform only when `camera.active` was set, which is only true
between `begin_drawing_2d` and `end_drawing_2d`. The natural place to ask where the mouse
is in the world is update code, which runs outside that pair, so it quietly returned a
screen position everywhere it was actually useful.

Split the flag, as the note suggested: `active` still means "a world-space draw is in
progress" and is what `screen_pos` reads, while a new `in_use` is set the first time
`begin_drawing_2d` runs and stays set. `get_mouse_world_pos` keys off `in_use`, so it
works anywhere in the frame. A game that never draws through a camera still gets the
plain screen position back.

## Fixed Resolution Is Always On

`init` ended by calling `set_logical_size`, which unconditionally set `fixed_res = true`,
so every window got letterboxed whether or not a logical resolution was asked for. That
call is gone -- it only ever re-set the width and height `init` had already assigned, so
flipping the flag was its entire effect.

Letterboxing is now opt-in: without `set_logical_size`, the logical size follows the
window and a resize just gives you more room to draw in. Pong asks for it explicitly,
since its paddle bounds and ball collisions are written in terms of a fixed 1080x720.

## Removing mbi

`mbi` was a main scoped struct that contained everything Matchbox needs to run
effectively. While added originally to make everything explicit and clear, having to
type `&mbi` everywhere started to hurt.

It is now a package-level global, so no procedure takes it as an argument any more:
`matchbox.draw_sprite(&mbi, player)` became `matchbox.draw_sprite(player)`. The struct
itself stuck around as one place to find everything, but the god struct is now split
into per-subsystem structs that live in the file that owns them -- `Display`, `Clock`,
`Renderer`, `Input`, `Camera`. `display` and `clock` are `using` fields so `mbi.width`
and `mbi.delta_time` still read flat, while the GPU plumbing stays behind `mbi.renderer`.

Accessors cover the common reads: `is_running()`, `delta_time()`, `get_mouse_position()`.
`poll_events` and `begin_drawing` now `ensure(mbi.initialized)`, since a global starts
zeroed and the old required argument was what used to make "call init first" a compile
error.

The one thing given up is multiple windows: one global means one instance per process.
