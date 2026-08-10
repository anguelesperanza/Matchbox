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

## Rectangle.position Meant Two Different Things

`draw_rect` passed `rectangle.position` straight to the vertex shader, which centres the
quad on it, so position was the middle of the rect. `mouse_over_button` tested
`position <= mouse <= position + size`, which is top-left semantics. A `Button` therefore
drew half a rect up and to the left of the box that responded to the mouse -- the two
overlapped by exactly a quarter of the button, so three quarters of what you could see
was dead and an equal patch of empty background beside it was silently clickable.

`mouse_over_button` turned out to be the only thing that disagreed. `draw_rect` and pong,
which does `position +/- size / 2` in every wall and paddle check, both already treated
position as the centre.

`Rectangle` grew a `pivot` like `Body`, and `rect_center` / `rect_top_left` derive the two
points everything else needs, so there is one place that decides what `position` means.
The zero value {0, 0} keeps position at the centre, which is what every existing literal
was already assuming -- so nothing moved and pong still plays. Buttons can now ask for
{0.5, 0.5} and be laid out from their top-left corner, which is the useful case.

Worth remembering: this pivot is the opposite way round from most engines, because it is
the fraction of the size *added to position to reach the centre*. {0.5, 0.5} means
position is the top-left. That was already true of `Body`; it is now true in two places.

## draw_button Put Its Text Above The Button

`draw_button` drew its label at `position + 2`, which assumed `position` was the top-left
corner and that `draw_text`'s y was a top edge. Both were wrong: position is the centre,
and `draw_text_string` passes y to `GetBakedQuad` as a *baseline*, so glyph bodies sit
above it. The label landed outside the box on both axes.

`Font` now records the `size` it was baked at along with `ascent` and `descent`, measured
off the baked glyphs, and `measure_text` reports how much room a string takes. Its height
is ascent plus descent rather than the extent of those particular glyphs, so text does not
shift vertically as its content changes. `draw_button` uses both to centre the label in
the box and add the ascent so it sits on the right baseline.

This also gives games a way to size a box to its text, which there was no way to do
before -- Silver at 32 makes "Play Card" 78 units wide, so a 40-wide button was never
going to hold it.

## Camera Zoom Moved Things Without Resizing Them

Every draw call pairs `screen_pos` with `screen_size`, but only `screen_pos` applied
`camera.zoom`. Positions were pulled towards the centre of the screen while sizes stayed
at their full pixel dimensions, so zooming out did not shrink anything -- it just packed
full-size sprites closer together until neighbours laid out with a clear gap between them
visibly overlapped.

Nothing caught it earlier because the camera example never leaves `zoom = 1.0`, where the
two agree. `screen_size` now applies the zoom whenever the camera is active, which fixes
sprites, animations, text, rects and outlines together, since all five go through it.

## No Mouse Wheel Input

`poll_events` handled motion and buttons but dropped `.MOUSE_WHEEL` on the floor, so there
was no way to write scroll-to-zoom without reaching past Matchbox into SDL.

`Mouse` grew a `wheel: [2]f32`, reset each poll like `mouse_dx`/`mouse_dy` since it is a
per-frame delta rather than absolute state, and `get_mouse_wheel` reads it. A `FLIPPED`
wheel (natural scrolling) reports the opposite sign, so that is normalised in
`poll_events` rather than left for every game to rediscover.

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
