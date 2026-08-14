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

## There Was No Way To Draw Something Over Something Else, Or To Stop It Being Clicked Through

The card game's deck builder wanted dropdowns to filter a hundred cards by type,
subtype, archetype and level. Two things stood in the way, and neither was the
dropdown itself.

Drawing is immediate, so what is drawn last is on top and nothing knows what is
above it. An open list has to appear over the card grid, but the grid is drawn
after the filter row -- so a list drawn where its box is would go underneath the
very thing it needs to cover.

And there was no notion of input being taken. Every widget tests the mouse for
itself, so the click that picks an option out of an open list also lands on
whatever that list was covering. In the deck builder that meant choosing
"Authority" would quietly add a card to the deck.

`Dropdown` therefore comes in two halves. `dropdown` draws the closed box and
takes *all* of the input, including the hit test on the open list, so a caller
learns about a change in time to act on it the same frame. `dropdown_overlay`
draws the open list and is called late, from the end of the screen, where it
lands over everything.

The input half is `mouse.captured`, cleared by `poll_events` like `wheel` and
set by `capture_mouse` while a list is open. `button`, `button_confirm`,
`hover_dwell` and `Text_Field` all ask `mouse_captured` themselves, so a button
under an open list neither lights up nor answers -- that seemed better than a
rule every caller has to remember. Anything hit-testing by hand still has to
ask; the deck builder's card grid does.

Worth remembering: capture only reaches widgets that run *after* the dropdown,
because it is a flag set during the frame rather than a hit test against a
stack. Draw the thing that opens out before the things it covers.

Still to do if something needs it: the list always opens downwards, which will
be wrong for a box near the bottom of a window. Left undone deliberately rather
than written untested.

## A Grid Of Three Drew Three Enormous Cells

`grid_fit` sized its items from `clamp(cols, 1, count)`, so the item size
depended on how many items there were. Twelve cards filled the area at their
proper size; filter down to one and that card was stretched across the whole
width of the pool.

It had always been that way and nobody had noticed, because nothing had made
short grids common. Filter dropdowns make them the normal case -- the count is
exactly what changes as somebody narrows a search.

The column count for *sizing* now comes from the area alone, and `count` only
decides how many of those columns get used and therefore how many rows there
are. Three items where twelve would fit draw at their proper size with a gap on
the right, which is what a partly filled row should look like.

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

### Fixed

The trap was closed during the move to SDL3_GPU. The shader now takes the border as a
per-axis half-extent, which puts the choice where the size is known -- at the call site
-- rather than leaving one number to mean two things:

- `draw_outline` takes a **thickness in pixels** and divides by size per axis, so it is
  even the whole way round. This is what the name always suggested.
- `draw_outline_proportional` takes the fraction and passes it on both axes, which is
  exactly the old behaviour, kept for the card zones.

The units changed with the meaning, and nothing warns about it: a call passing `0.04`
still compiles and now draws a line four hundredths of a pixel wide, which is to say
nothing at all. Every existing `draw_rect_outline` / `draw_bounding_box_outline` call
has to be looked at -- either scaled up to pixels, or switched to
`draw_outline_proportional` to keep what it had.

`examples/outline` draws both on a 460x52 box, which is the shape the difference shows
up on.

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

## Left For Later After The SDL3_GPU Move

The backend move deliberately changed as little as it could get away with, so a
difference in the picture meant a porting mistake and nothing else. That left a
few things standing that are worth coming back to. None of them block anything.

### The Arc B580 has not actually been tested

This is the one that matters, because it is the machine the whole move was for.
Everything was verified on an NVIDIA card, which could run the old backend fine
and so proves the least interesting half of the claim. SDL3's Vulkan backend
asks for nothing Intel withholds, and D3D12 is there underneath it either way,
but that is reasoning rather than evidence until the branch is built on the B580.

### Text draws one quad per glyph

`draw_text_string` binds the font pipeline once and then pushes a fresh uniform
block and issues a draw for every character. A line of twenty characters is
twenty draws. That was true before the move as well, and it is correct -- it is
just the obvious thing to batch: one vertex buffer built per string, or per
frame, and a single indexed draw.

Worth measuring before rewriting. Nothing here draws enough text for it to
matter yet, and a batched path is more code than the loop it would replace.

### Flipping a spritesheet frame samples the wrong tile

`sprite.frag` flips uv after `uv_min`/`uv_max` have already narrowed it to one
tile:

```hlsl
if (flip_x != 0) uv_final.x = 1.0 - uv_final.x;
```

On a full-sheet sprite where uv runs 0..1 that is right. On a frame picked out
by `sprite_set_frame` it reflects around the middle of the whole atlas instead
of the middle of the tile, so a flipped frame shows some other frame. The fix is
to reflect within the sub-rect -- `uv_min + uv_max - uv` -- rather than within
the unit square.

Pre-existing, and ported across unchanged on purpose so that anything that
looked different after the move was the move's fault. `draw_animated_sprite`
sidesteps it by folding the flip into the uv bounds it hands over, which is why
this has not been noticed.

### random-walk does not build

```
examples/random-walk/main.odin(29): Too few values in structure literal, expected 5, got 4
```

A positional `Rectangle` literal that was not updated when `pivot` was added. It
has nothing to do with the backend and was already broken on main, so it was
left out of that branch rather than folded into an unrelated diff. Switching it
to a named-field literal is the fix, and is what stops it happening again the
next time the struct grows.

## A Steam Controller In Mouse Mode Was Steam's Doing, Not The Controller's

A Steam Controller -- the 2026 one, on its wireless dongle -- appeared to be stuck
acting as a keyboard and mouse. The right trackpad drove the cursor, the right
trigger clicked, and X opened the on-screen keyboard. Inside Steam the same pad
behaved as an ordinary controller.

That reads exactly like lizard mode, which is the state these controllers boot into
and stay in until something claims them, and it is the wrong answer. Two separate
things were stacked on top of each other and neither was Matchbox.

### It was Steam's Desktop Layout

Steam applies a desktop configuration to a controller whenever the foreground
program is not a game it launched. Its defaults are right trigger to left click and
X to the on-screen keyboard -- which is to say, the exact symptoms, item for item.
Steam had been running for a week.

The tell was that gamepad input arrived *at the same time*. Buttons and axes came
through normally while the cursor was also moving, because two things were reading
the pad at once. Lizard mode would not do that; it emulates instead of reporting,
not as well as.

Nothing to fix. Players who own one of these launch games through Steam, where
Steam Input applies the game's layout rather than the desktop one and hands over a
clean virtual controller. For development, add the game to Steam as a non-Steam
shortcut, which also tests what players actually get, or turn off the desktop
configuration under Steam -> Settings -> Controller.

### SDL does not drive this controller at all

Underneath that, SDL 3.4.2 never claims the device. Probed with
`SDL_JOYSTICK_HIDAPI_STEAM` set and unset, the results are identical:

```
path: \?\HID#VID_28DE&PID_1304&MI_02&Col03#...
type: STANDARD (real STANDARD)
underlying joystick: 6 axes, 16 buttons
```

A raw Windows HID path rather than a hidapi one, and a generic type rather than
anything Valve-specific. SDL is reading one interface collection of a composite
device as an ordinary gamepad -- which works, and is why the pad is usable, but it
is a fallback rather than support. Product `0x1304` is not the 2015 controller's
`0x1102`, and SDL's driver only knows the older one. That gap is upstream and
nothing set from this side moves it.

### The part worth remembering

The first version of that probe was run with Steam still open, and the conclusion
drawn from it -- "the hint changes nothing, so SDL cannot drive this pad" -- did not
follow. **SDL's Steam driver deliberately stands aside when Steam is running**, so
identical results with and without the hint had two explanations and the evidence
could not tell them apart. It only became a real measurement once Steam was fully
exited and the probe was run again.

The technique that settled it was a listener that printed gamepad events *and mouse
motion* side by side for twenty seconds. Which channel input arrives on is the whole
question, and a static device listing cannot answer it: a controller can be listed,
typed, mapped and completely silent.

`matchbox.steam_controller_mode` came out of this and lives on the unmerged
`steam-controller-mode` branch. It enables SDL's driver unless Steam launched the
game, which is right for the 2015 Steam Controller and for a Steam Deck's built-in
controls. It does nothing for `0x1304` and was never merged as though it did.
