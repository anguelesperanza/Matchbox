# Improvements

This file lists improvents I can make to Matchbox that I discovered while trying to create things.
These things might not have been finished and that's fine, what matters is that I discovered these
areas of improvement while trying to create them.

---

# Not Started

## A Hit Test That Knows About The Clip

Found converting the card game's deck builder from paging to Scroll_View, which
is the first thing to use a clip for what it was added for.

`mouse_over_rect` asks whether the pointer is inside a rectangle and nothing
else. Inside a scrolling panel that is the wrong question: a row scrolled past
the bottom edge is cut out of the picture by the scissor and still answers the
mouse, because the scissor is a drawing state and the hit test never looks at
it.

What that cost the game: the deck panel's Empty button sits in the panel's foot,
below the scroll area. With the list scrolled, a content row lands underneath
that button -- invisible, and still hit-testable -- so pressing Empty also
pressed the `-` of whatever row happened to be there. Same shape as clicking
through an open dropdown, which `mouse_captured` already solves, and the same
answer is wanted here.

The game works around it by testing the panel as well as the row:

	inside := matchbox.mouse_over_rect(area) && !matchbox.mouse_captured()
	...
	over := inside && matchbox.mouse_over_rect(spot)

That is correct and it is a rule every caller has to know, which is what makes
it worth moving. Two shapes suggest themselves:

  - `mouse_over_rect` intersects against the current clip stack, so it is right
    by default and nobody has to be told. Anything wanting the old behaviour
    can still call `point_in_rect` with `get_mouse_position()`.
  - or `scroll_contains(view, rect)` for the narrower case, which leaves
    `mouse_over_rect` alone.

The first is the one that stops this being discovered again. `apply_clip`
already keeps the current rectangle, so the test has something to ask.

Worth checking `hover_dwell` at the same time -- it has the same problem for the
same reason, and the game resets the dwell state by hand for exactly that.


## Remove / Reduce AI Code

While I wrote a chunk of this, so did Claude. I'd like to
reduce the AI code as I make breaking api changes,
optimazations, etc

## Reduce System Usage

Basic Init Window example uses about 53mb of ram.
Need to compare to other frameworks to see if that's a lot?

Not started, but one thing did turn up while testing the font cache with a
tracking allocator: a whole start-and-stop leaked exactly one allocation, the
five bytes of the window title, which `init` cloned to a cstring and handed to
SDL_CreateWindow without ever giving back. SDL copies the title, so it was ours
to free. Fixed, and worth writing down mostly for the method -- a tracking
allocator around `init` / `cleanup` is a two minute test and it now comes back
clean, which makes the next leak easy to see. 53mb is not made of that sort of
thing, though; the atlases and textures are where to look.

---

# Completed

## An Emulator Could Not Draw Its Screen

Two emulators written against Raylib -- a Chip-8 and a Game Boy / Game Boy Colour
-- were the test of whether matchbox could do this at all. Audio was out of
scope; this is only the picture.

The answer was one missing thing, and it was the whole of it. Every emulator ever
written draws the same way: keep one texture the size of the machine's screen,
rewrite its pixels once per emulated frame, and scale it up with
nearest-neighbour filtering so the pixels stay square. The Game Boy backend does
that with `UpdateTexture` in Raylib and `LockTexture`/`UnlockTexture` in SDL2.

Matchbox could do neither half. Every texture it had came from a *file* --
`create_sprite` takes encoded bytes and hands them to stb -- so there was no way
to hand over a buffer you had filled in yourself, and no way at all to change one
after it existed. `upload_texture` did the right upload and was private, made a
new texture every call, and submitted its own command buffer.

That last part is why "call create_sprite every frame" is not the answer even
before counting the cost. It would allocate a texture and a staging buffer per
frame, submit a second command buffer per frame, and leak the previous
texture -- and releasing the previous one is not safe while the GPU may still be
reading from it.

`Pixel_Buffer` keeps one texture and one transfer buffer and records the copy onto
the frame's **existing** command buffer. Both are cycled rather than
double-buffered by hand, which SDL3 will do on request, so writing into the
staging buffer never waits for last frame's copy to finish.

	screen := matchbox.create_pixel_buffer(160, 144)
	defer matchbox.destroy(&screen)

	matchbox.begin_drawing()
	matchbox.pixel_buffer_update(&screen, ppu.framebuffer[:])
	matchbox.clear_background(matchbox.BLACK)
	matchbox.draw_pixel_buffer(&screen, matchbox.pixel_buffer_fit(&screen))
	matchbox.end_drawing()

`pixel_buffer_update` takes a slice of anything four bytes wide -- `[]u8` four to
a pixel, `[][4]u8`, `[]u32`, an emulator's own `[]COLOR` -- and checks the total
against the buffer, so a mismatched stride is a panic rather than a picture that
looks nearly right.

A copy pass cannot be opened while a render pass is recording, so this closes one
if it finds it open and the next draw reopens it with `load_op = .LOAD`. Calling
it before `clear_background` avoids that entirely, which is what the example
does. Being on the frame's own command buffer is also what orders the upload
against the draw that reads it: Raylib's backend carries a comment about Windows
drivers deferring uploads made outside the draw context and `DrawTexturePro` then
reading stale pixels, and that is a problem this arrangement does not have.

### The thing worth having beyond the texture

`pixel_buffer_fit` returns the biggest box of the buffer's own shape that fits an
area, centred. Both emulators stretch to fill the window instead, which distorts
the picture whenever the window is not an exact multiple of the machine's aspect
ratio, and both compute that rectangle by hand.

`integer = true` snaps the scale down to a whole number so one source pixel is an
exact block of screen pixels. That is not fussiness. At 3.972x some rows of a
Game Boy screen are four screen pixels tall and others three, and on a dithered
gradient the seams are visible and they wander. The cost is a margin, and it can
be a large one -- a 723x611 window is four pixels short of 4x, so it drops to 3x
and gives up a quarter of the image. That is the trade, and it is why this is a
flag rather than the default.

`examples/framebuffer` animates a Game Boy-sized buffer with a one-pixel
checkerboard in the corners and a lit pixel every eighth, which is what makes an
uneven scale visible rather than theoretical.

### Two things found on the way, both older than this

**The frame limiter drifted, and not for the reason it looked like.** It waited
"the frame period minus however long this frame took", through `sdl.Delay`, which
takes whole milliseconds. The truncation was the obvious suspect and was the
smaller half: the real fault was that nothing ever made up for a wait that came
back late, because the error was measured fresh each frame and any overshoot was
simply kept.

Measured over 180 frames at a Game Boy's 16.742706 ms, it ran **1.4 to 1.6
percent fast** -- about 60.6 fps against 59.7275 -- and repeatable to within a
fifth of a percent, so it was the model rather than noise. An absolute deadline
that advances by exactly one period whatever the last frame cost, waited on with
`DelayPrecise` in nanoseconds, comes in at **0.22 percent under**. Roughly seven
times better, and the residual is close to what the measurement itself can see.

Worth writing down that the first guess was wrong by a factor of three. Reasoning
from "16.742706 truncates to 16" gives four percent; the sleep is only the
*remainder* of the frame, so the truncation loses under a millisecond of a
sixteen millisecond wait. The number came from measuring it, and there was no way
to get it by thinking harder.

There is now a catch-up limit as well: past four frames behind, the debt is
written off. Without it a window dragged for two seconds leaves a hundred frames
owed and the loop runs flat out with no wait at all trying to serve them.

**The window size was in the wrong units on a scaled display.** `init` asks for
`.HIGH_PIXEL_DENSITY`, which gets a surface at the display's real resolution --
on a display at 125% a 640x480 window has an 800x600 swapchain -- and
`begin_drawing` read `GetWindowSize`, which reports points.

Nothing looked broken, which is why it lasted: `screen_dims` hands that number to
the vertex shader as the divisor, so a full-width rectangle still reached the edge
of the window. What was lost was the resolution that had been asked for. The whole
frame was composed at point resolution and stretched over the pixels, so text
baked at 32 was drawn across 40 and came out soft. For a nearest-filtered pixel
image it is worse than soft: one source pixel lands on 1.25 screen pixels and the
seams fall in different places down the image, which is exactly the artefact
`integer` scaling exists to avoid.

`GetWindowSizeInPixels` now, and the mouse converted by the window's pixel
density, since SDL reports the pointer in points. Fixing only the first half
would have traded a soft picture for hitboxes a quarter of the way out and
getting worse further down the screen.

**This is unverified at a scale other than 1.** The display here reports 1.00, so
the two agree and the change is a no-op on it -- everything still builds and runs,
which is all that can honestly be claimed. The evidence that it matters is
second-hand and good: the Game Boy emulator's Raylib backend works around exactly
this with `GetRenderWidth`/`GetRenderHeight` and leaves a comment naming the
numbers, "125% DPI: 480x432 logical -> 600x540 physical".

### Still missing, and deliberately

Chip-8 draws up to 2048 rectangles a frame, and `draw_rect` rebinds the pipeline,
the vertex buffer and the index buffer for every one of them. It would run, and
the better port is the same one as the Game Boy: a 64x32 pixel buffer and one
draw. Nothing in matchbox batches anything -- the same note already sits against
text drawing one quad per glyph -- and that is still true and still not urgent.

## The Eight Things The Card Game Had Written For Itself

All eight are in matchbox now, and the game's copies can go. Taken together
they are one complaint rather than eight: matchbox had the *hard* half of each
of these -- clipping, capture, plates, dwell -- and none of the twenty lines
that turn it into something a screen can use.

**A button that could not be pressed.** `Button_Style` grew `disabled`, and
`button` draws a dimmed version of whatever colour it was handed, never
highlights, and never returns true. The dim is a *factor* rather than a second
colour, so it works against any palette without being told about it -- a colour
would have meant every caller picking one, which is most of what the
hand-rolled version was doing. `button_enabled_if(condition)` is the shape it
is nearly always wanted in.

Worth saying plainly, because it is the second time this has happened: `button`
was added to absorb what every wrapper around Button/draw_button/
mouse_over_button ended up adding, and it absorbed the size and the alignment
and missed this -- so the biggest wrapper in the game survived it. The lesson is
not "add a disabled flag", it is that a widget which cannot express *not now*
is not finished.

**A scroll view.** `Scroll_View` holds an offset in pixels, clamps it to the
content, takes the wheel, and brackets `begin_clip`/`end_clip`. `begin_scroll`
hands back the point to lay content out from, so items are positioned where
they naturally go and the ones outside are cut off by the scissor.

The offset being pixels rather than an index is the whole of why this deletes
the pagers. Paging forced every view of the same list to work out its own
per-page count, because how many things fit on a page is a different question
from how many things there are -- and it is a question the *content* can answer
and the *list* cannot. Nothing here asks it.

The bar is drawn as well, and can be dragged, which the note did not ask for:
the bar had to exist either way to say where in the list you are, and once it is
on screen it looks draggable. `scroll_to` is there for a selection moved by the
keyboard.

**A context menu, folded into Dropdown.** `Dropdown` grew an anchor. A box, and
the list opens under it as before; a point, and it opens there, which is a
context menu. `open_context_menu` and `context_menu` are the point half; the
list is drawn by the same `dropdown_overlay` as before.

Two things came out of doing it this way rather than as a second widget. The
list now flips **upwards** when there is not room below it, which was the item
left undone on the grounds that nothing had been put near the bottom of a window
yet -- a context menu opens wherever the pointer is, and the bottom of a window
is an ordinary place to right-click. And it slides left off the right edge for
the same reason. `dropdown_row_rect` is derived from the list rectangle rather
than from the anchor, so the hit test cannot go on believing the list opened
downwards after it has been flipped, which is exactly the bug this shape of code
invites.

One thing that had to be handled and is worth remembering: the click that opens
a menu is still a press for the rest of that frame, and the point it opens at is
the top corner of the first row. Without `opened_on`, every menu opened and
chose its own first entry in the same breath.

**A tooltip.** `draw_tooltip` puts wrapped text on a plate beside the pointer
and moves it to the other side of the cursor when it would run off, then slides
it inside the window if neither side fits. Flipping before sliding is deliberate
-- it keeps the plate off the cursor, and sliding is what is left when there is
nowhere good to go.

**A status line.** `Status_Line` with four levels, and a fade for a message
given a time limit. The text is **copied into a fixed buffer**, which is the one
decision in it worth defending: these messages are nearly always
`fmt.tprintf`, and a status line holding the pointer would be drawing freed
memory by the next frame -- a bug that looks like a rendering fault for an
afternoon.

**A labelled field.** `Text_Field` grew `label`, drawn above the box.
`rectangle` still means the box and nothing else, so the hit test, the focus
ring and the caret are untouched; `text_field_place` and `text_field_height` are
how a form lays one out, since a labelled field takes up more room than its
rectangle says.

**A modal.** `Modal`, in two halves like `Dropdown` and for the same reason:
`modal_begin` takes the pointer at the top of the frame so the screen underneath
does not answer clicks meant for the modal, and `modal_overlay` draws the dim
last and hands back a centred box. The overlay *releases* the pointer as it
draws -- without that, buttons inside the modal ask `mouse_captured()` like
every other button and come out as dead as the screen behind them.

It shipped broken, and the way it broke is worth keeping. A modal opened and
vanished in the same frame: the click that opens one is still a press for the
rest of that frame, `modal_overlay` handed the pointer back, and
`modal_dismissed` then saw a live press outside the content box -- the button
that opened it -- and shut it again. One frame of dim, which reads as nothing
happening at all.

This is the *same bug* that was found and guarded in `context_menu` a few hours
earlier, in the same sitting, and it did not occur to me to look for it next
door. Both widgets are opened by a click and both draw during the frame of that
click, so both have to say "not this one". Anything else opened by a click and
drawn immediately needs the same guard, and that is now three places worth
checking rather than a quirk of dropdowns.

The fix is a frame stamp, as it was for the menu, but applied differently:
`modal_overlay` *holds* the pointer on the opening frame instead of giving it
back. That way the one press reaches nothing -- not `modal_dismissed`, and not a
button inside the box that happens to sit where the opening button was, which a
guard on the dismissal alone would have missed.

**A progress bar.** `draw_progress`, and `draw_progress_labelled` for one with
room for text on it. `examples/ui` drew this out of a hand-made rectangle, which
is where the case for it came from, and now calls it.


## Drawing That Was Not A Rectangle

**A tint on a sprite.** `Body` grew `tint` and `desaturate`, and `sprite.frag`
grew the uniform block to take them. Dimming a card is now a property of the
draw rather than a translucent rectangle drawn over the top of it -- which
worked, and cost an extra draw, and could only ever darken.

The zero value is the part that needed thinking about. An all-zero tint is read
as "as it was painted" rather than "multiply by transparent black", because a
Body nobody has filled in has to draw the picture: every sprite predating this
has a zero there and the alternative is that all of them silently stop
appearing. The two readings do not otherwise collide -- fading out is
`{1,1,1,a}`, which stays non-zero all the way down to a = 0.

`desaturate` is a separate number rather than another tint because a multiply
cannot take colour away, only add or subtract it. It is applied *before* the
tint, so tinting a greyed sprite gives a picture in the tint's hue; the other
order washes the tint out along with everything else and there is no way back.

**Lines, circles, ellipses and triangles.** `draw_line`, `draw_lines`,
`draw_circle`, `draw_circle_outline`, `draw_ellipse`, `draw_ellipse_outline`,
`draw_triangle`, `draw_triangle_outline`.

A line is a rotated rect and goes through the rect pipeline, because that is
genuinely all it is. The other three are cut out of the same unit quad by a
distance field in a new `shape.frag`: the quad covers the shape's bounding box
and each pixel is tested. The honest version is a second vertex format and a
second pipeline layout, and this keeps the one shared quad, the one vertex
shader and the one vertex format the whole renderer is built on -- a triangle
costs what a rect costs.

Every `thickness` is in **pixels**, and the shader converts using the
screen-space gradient of the distance field. That is worth knowing because it is
the thing `draw_rect_outline` spent years getting wrong: the quad may be
stretched, rotated, scaled by the letterbox and zoomed by the camera, and all of
it arrives already folded into that one number, so a ring is one thickness the
whole way round whatever has been done to it. The edges are smoothed for free
out of the same number.

Two things this cost. The shapes are described in the quad's own uv space rather
than inscribed in it, so the quad can be padded -- a shape drawn flush to the
quad's border loses the outer half of its smoothed edge. And the triangle's
winding is worked out from the third corner, which took one wrong sign to learn:
getting it backwards does not draw a mirrored triangle, it draws **nothing at
all**, because three half-planes all facing inwards have no overlap to fill.

`Dropdown` draws its caret as a triangle now, sized off the box rather than off
the font. It was the ASCII characters `v` and `^`, which meant the caret was
whatever shape the game's font happened to give those two letters, at whatever
size the text was.

**Text at more than one size.** `get_font(size)` bakes the default font at any
size and caches it, so a layout worked out as a fraction of the window can size
its words the same way:

	font := matchbox.get_font(f32(matchbox.mbi.height) * 0.03)

Sizes are rounded to whole pixels, which is stb's resolution anyway, so dragging
a window rebakes only when it crosses a pixel. The cache holds six, because each
size is a 512x512 RGBA atlas -- a megabyte of texture apiece -- and six covers a
title, a heading, body text, a caption and two odd ones.

The limit needed a guard that is worth remembering, because it is the sort of
thing that would have gone unnoticed for months: eviction never touches a size
asked for during the current frame. A screen drawing seven sizes would otherwise
free the atlas belonging to a pointer it handed out moments earlier and is still
drawing through. Going one over the limit for a frame is much the cheaper
mistake. `Clock` grew a `frame` counter to make that testable, which is useful
on its own.

And then the guard needed a guard, which a tracking-allocator test caught and
nothing else would have. `mbi.frame` is 0 until the first `poll_events`, and so
is every `used_on` recorded before then -- so sizes baked during setup all
looked like they were in use by the frame that had not started yet, and the
limit did nothing at exactly the moment a game is most likely to ask for a dozen
sizes at once. Eight sizes stayed resident against a limit of six. The test asks
for eight and expects six, which is the sort of thing worth keeping.

`get_font(32)` hands back `mbi.font` rather than baking a second copy of it.
`DEFAULT_FONT_BYTES` is exposed for a game that would rather keep its own set.

**Wrapped and multi-line text.** `wrap_text`, `draw_text_wrapped`,
`draw_text_lines`, `measure_text_wrapped`, `text_block_height`, `line_height`.

These take a **top-left**, not a baseline, unlike `draw_text`. Text that wraps
is being fitted into a box rather than typeset onto a line, and the box is what
the caller has. Lines break at spaces and at any `\n` already there; a blank line
in the source is a blank line on screen, since that is the only way to ask for a
gap. A word wider than the whole column is broken where it runs out of room --
there is nowhere else for it to go, and quietly overflowing is the one outcome
somebody who passed a width did not want.


## A destroy Procedure Group

`destroy` takes any of Mesh, Sprite, AnimatedSprite, AnimationClip,
ParallaxSprites, Font, Sound, Text_Field and Sprite_Cache. Every `destroy_`
procedure is still there and still callable; this only saves remembering which
one goes with which type, and saves changing the call when the type changes.
Odin picks by argument type, so getting it wrong is a compile error rather than
a leak, which is the whole point.

`destroy_animated_sprite` is new and came out of writing the group: there was no
such procedure, so a game holding an AnimatedSprite had to know the thing to
free was the clip inside it and reach past the sprite to do it. Everything else
in the group frees itself.

`cleanup` is deliberately not in the group. It is called once, at the end, and
it is not one more thing to free -- everything else in the group stops working
after it.


## The UI Was Spread Over Four Files And Should Have Been One

`ui.odin` was getting long, so the new work went into new files: a
`widgets.odin` for the tooltip, status line, modal and progress bar, a
`scroll.odin`, and a `dropdown.odin`. Length is a real problem. That was not an
answer to it.

"Widgets" and "ui" are the same word. Somebody looking for a tooltip had no way
to guess which of the four files it was in, and the boundary I would have had to
defend -- the small ones together, the big ones apart -- is one nobody could
have predicted from outside. A rule that has to be read before it can be
followed is not doing the job a file layout is for.

It is all in `ui.odin` now, about 1770 lines, and the header lists what is in
it. One long file you can search beats four you have to choose between; the
split was solving my problem reading it rather than a caller's problem finding
things in it.

`examples/widgets` went the same way and is part of `examples/ui`, which shows
all fourteen on one screen -- and, more usefully than any single widget, shows
the **order** they have to be called in. That ordering rule is the thing that is
actually easy to get wrong here, and both bugs found while building this came
straight out of it.

`Layout` and `Grid` stay in `layout.odin`, and that one is defensible on a
distinction a caller can see without being told: they draw nothing and answer no
input. They hand back Rectangles, and everything in `ui.odin` takes one.


## What The Game Has To Change

Almost nothing. The additions above are additions, and the zero values were
chosen so that code written before them keeps its behaviour.

The one signature that changed is `dropdown_row_rect`, which now takes the
option count as well, because the row is derived from the list rectangle rather
than from the anchor -- that is what keeps the hit test right after the list has
flipped upwards. Anything calling it directly needs the extra argument; nothing
calling `dropdown`, `dropdown_overlay` or `dropdown_row_at` is affected.

`button`, `dropdown`, `dropdown_overlay`, `draw_text_field`, `draw_tooltip`,
`draw_status` and `draw_progress_labelled` all take an optional trailing
`font`, defaulting to `mbi.font`. Existing calls are unchanged.

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

### random-walk does not build -- fixed

```
examples/random-walk/main.odin(29): Too few values in structure literal, expected 5, got 4
```

A positional `Rectangle` literal that was not updated when `pivot` was added. It
has nothing to do with the backend and was already broken on main, so it was
left out of that branch rather than folded into an unrelated diff.

It is a named-field literal now, which is the fix and is also what stops it
happening again the next time the struct grows. Every example builds.

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
`steam-controller-mode` branch, at `89e9d89`. It enables SDL's driver unless Steam
launched the game -- `AUTO` / `NATIVE` / `LEAVE`, deciding by whether `SteamAppId`
is in the environment, and setting the hint before `SDL_Init` because a hint read
at subsystem startup is worth nothing afterwards. That is right for the 2015 Steam
Controller and for a Steam Deck's built-in controls. It does nothing for `0x1304`
and was never merged as though it did.

### The branch had to be recovered

That paragraph said the branch existed for three days after it had stopped
existing. Deleted at some point and not noticed, because nothing builds it and
nothing points at it -- a note in a file is not a reference anything checks.

It came back out of the reflog, which is the only reason it came back at all:
reflog entries expire after ninety days by default, so an unmerged branch nobody
has looked at for a quarter is gone for good and the note describing it stays
exactly as confident as before. Worth remembering the next time something is
parked on a branch rather than merged behind a flag.

It rebases onto main cleanly and all fourteen examples build on top of it, so
the parking is still cheap:

	git rebase main steam-controller-mode

### Where the actual answer is, for next time

The question that keeps coming back is "how do I put the controller in gamepad
mode rather than desktop mode", and the answer is that **there is no SDL setting
for it.** Steam decides, before SDL sees the device. Launch the game through
Steam as a non-Steam shortcut, which is what players get anyway, or turn the
desktop configuration off under Steam -> Settings -> Controller.

Upstream has the 2026 controller on its list -- libsdl-org/SDL issue 15471 -- so
the thing to watch is an SDL past 3.4.2, which is still what is vendored here.
Until then `0x1304` arrives as a generic HID gamepad: six axes, sixteen buttons,
no trackpads, no gyro, no back buttons.
