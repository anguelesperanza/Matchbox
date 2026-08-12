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

## A Sampler Per Sprite Capped The Whole Program At Two Dozen Sprites

`create_mesh` allocated a fresh sampler for every sprite, and `desc_pool_create` gives the
sampler pool a default capacity of 32 against 65536 for textures. Every one of those
samplers was identical -- nearest filtering, no other state -- so the pool filled up with
copies of one thing and then

	gpu.odin(980) runtime assertion: pool.res_count + u32(count) < pool.res_capacity

The card game hit it building a 60 card deck, but the real ceiling was about two dozen
sprites alive at once, whatever they were.

Samplers are immutable state objects meant to be shared. `init` now allocates the one
nearest-neighbour sampler and every sprite references it, which takes the count from
"one per sprite" to one, full stop.

`destroy_mesh` was also giving nothing back to the descriptor pool -- neither the sampler
nor the texture. The sampler no longer belongs to the mesh, but the texture descriptor
does, and it is now freed. Without that the texture pool drained as sprites came and
went, just far more slowly than the sampler pool did.

## Image Loading Was Five Times Slower Than It Needed To Be

The card game took four and a half seconds to reach its first frame. Timing the stages
showed almost all of it was one thing: decoding PNGs. For a 750x1050 card, `create_sprite`
took 88.5ms of which `core:image` decode was 89.0ms -- the gpu upload and the
`queue_wait_idle` in `create_mesh` did not register at all. Batching the uploads, the
obvious-looking fix, would have bought nothing.

`core:image` is a pure Odin decoder and is not fast. Measured against `vendor:stb/image`
on the same files it is about five times slower: 89.0ms vs 18.7ms for a card, 323ms vs
67.8ms for a 1500x2100 image. stb was already linked for the font atlas, so moving
`create_mesh` onto it costs no new dependency -- `desired_channels = 4` gives the RGBA the
texture format wants, which is what `.alpha_add_if_missing` was there for.

Startup went from ~4530ms to ~1280ms with no other change. What is left is roughly 514ms
of `init` and the decoding that remains, so the next wins are fewer and smaller images
rather than a faster decoder.

Worth knowing for Linux: the README already says to run `make -C {Odin}/vendor/stb/src`,
which builds the image library along with truetype, so nothing new is needed there.

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

## Text Input, and a Text_Field to Put It In

There was no way to type anything into a Matchbox program. Not just no widget -- no SDL
text input at all, so a game asking for a name, an address or a password had nowhere to
start.

Scancodes are the wrong tool for it. `is_key_pressed(.A)` says which key moved, not what
the person meant by it: shift, the keyboard layout, dead keys and accents are all still
ahead of you, and anybody typing Japanese, Chinese or Korean goes through an IME that
turns many keystrokes into one character. Rebuilding that on top of scancodes means
reimplementing every keyboard layout in the world.

So `poll_events` now handles `.TEXT_INPUT` and `get_text_input()` returns what was typed
this frame as utf-8, already correct. It is per-frame like `mouse.wheel`, and the string
SDL hands over is only valid during the event, so it is copied out there and then.

Text input is off until `begin_text_input()`. That is not just bookkeeping: it is what
tells the platform somebody is about to type, and mobile on-screen keyboards and IME
candidate windows key off it. `end_text_input()` turns it back off, which matters because
while it is on the platform may swallow keystrokes to compose characters -- not what a
game wants during play.

`Key_State` gained `repeated` alongside `pressed`, set on auto-repeat as well as the
first press, read with `is_key_repeated`. Auto-repeat used to be dropped outright, so a
held backspace deleted one character and stopped. The two are kept apart rather than
folded together because they answer different questions: firing a weapon wants the first
press, deleting a character wants every repeat, and code written against one is wrong
with the other.

`get_clipboard_text` came along with it, since a password is the sort of thing people
paste.

On top of that, `ui.odin` gained `Text_Field`: a box, a caret, insert and delete at the
caret, arrows, Home/End, Ctrl+V, and a masked mode for passwords that stars per character
rather than per byte, so an accented letter does not become two. Clicking inside focuses
it and clicking away drops focus, which gives several fields on one screen exactly one
focus between them without their having to know about each other.

It deliberately turns text input on and never off. Doing both per field would let one
field switch input off in the same frame another switched it on, and which won would come
down to the order they were updated in -- so the screen that owns the fields ends it.

What it is not: there is no selection, no dragging the caret with the mouse, and no
scrolling when the text outruns the box. It exists for the short answers a game asks for.
Anything longer wants a real editor widget, not this one grown into one.

## An Outline Is Thicker On The Long Side

`draw_rect_outline` takes a `border`, and it is easy to read that as a thickness. It is
not. The outline shader compares it against uv, on both axes:

```glsl
if (uv.x > border) { if (uv.x < 1.0 - border) { ... } }
```

uv runs 0..1 across whatever the rectangle happens to be, so the thickness that comes out
is `border * size` **per axis**. On a square that is one number. On anything else it is
two, and the long side gets the heavy one.

It went unnoticed for a while because the only things using it were card-shaped zones at
150x210, where 0.02 is 3 pixels one way and 4.2 the other -- wrong, and not wrong enough
to see. A 460x52 text box is where it showed up: a border of 0.04 drew eighteen pixels
down each side and two along the top, and swallowed the first characters typed into it.

Rather than change the shader, `ui.odin` gained `draw_rect_border`, which draws four bars
at a thickness in pixels. The corners are covered twice, which a flat colour hides and
which is cheaper than mitring them to meet.

Both are worth having, so neither replaced the other:

- `draw_rect_border` when the border should look the same all the way round -- boxes,
  fields, panels, anything a person reads as a frame
- `draw_rect_outline` when it should scale with the shape, which is what the card zones
  actually want: their outline stays in proportion as the board zooms

The API is the trap here, not the maths. `border` is a fraction and reads like a width,
and nothing at the call site says otherwise.

## A Window Bigger Than The Screen

`init` passed the width and height straight to `SDL_CreateWindow`, so a game
written on a desktop and run on a laptop asked for a window the display could not
hold. What happens then is up to the window manager -- some clamp it, some leave
part of it off the screen where nothing can reach it -- and either way the game
believes it has a size it does not have and lays out for that.

It is capped to `SDL_GetDisplayUsableBounds` now. Usable rather than raw, so a
taskbar, dock or panel is already taken off. A display that cannot be measured
leaves the request alone rather than guessing at it.

This is a floor, not a solution. It stops a window opening larger than the
screen; it does not make anything drawn inside it fit. A layout written against
fixed pixel positions still runs off the edge of a narrower window, and the only
answer to that is laying out from `mbi.width` and `mbi.height`, which follow the
window every frame when a logical size has not been asked for.

The game that prompted this had a card grid of six fixed columns and lost the
last one on a 13 inch laptop. Capping the window would not have saved it -- it
now works out how many columns fit and sizes the cards to use the width exactly.
Worth saying plainly, because a cap like this looks like it solves more than it
does.

## Telling Somebody Else's Computer Why It Would Not Start

`init` panicked with "Could not initialize gpu library" and nothing else. The gpu
layer knew perfectly well what was wrong -- it builds a message naming the exact
extensions it could not find -- but it says so through `context.logger`, and
Odin's default logger discards everything. The diagnosis was being produced and
thrown away on every failure.

Three changes, all aimed at the same problem: the machine that cannot run the
game belongs to somebody else, and you may get one attempt at finding out why.

**A logger, when the caller has not set one.** Everything the gpu layer had to
say now reaches the console instead of the floor.

**A report file.** On a failed start, `gpu-report.txt` is written next to the
executable: every physical device found, with its name, type, vendor, driver
version and Vulkan version, which required extensions each one has and lacks,
and what to try next. A file rather than console output because the person it
has to reach double-clicked the game and watched it die -- asking them to run it
from a terminal reaches the author and nobody else. Beside the executable rather
than in the working directory, because a shortcut can start a program anywhere
and the folder they were given is the one place they will look.

**Devices are filtered before they are scored.** Selection used to take the
highest scoring GPU by type and only then ask whether it supported what the
renderer needs, so a machine whose best device was unsuitable gave up with a
second one sitting right there. The machine this was written on has a discrete
NVIDIA card and AMD integrated graphics, which is an ordinary laptop or desktop
and exactly the case that was broken.

The report is worth the hour it costs. It turns "it does not work on my friend's
computer" into a file naming a driver version.
