# Candidates To Bring Into Matchbox

Things a game built on Matchbox had to write for itself, and which look like they
belong in the framework instead.

Everything here comes out of one project -- Murica Brawler, a card game -- so
each entry names what exists there today and would move. That is deliberate:
every item has already been written once against a real need rather than
guessed at, and the code to lift is sitting in a working game.

Ranked by what it buys, not by effort.

---

## 1. Expose scissor clipping -- DONE

**The highest-value one by a distance, and the only one that removes a
constraint rather than saving typing.**

Now `begin_clip` / `end_clip` in `matchbox/clip.odin`, with `examples/clipping`
showing a list scrolling inside a panel. The rest of this entry is left as it
was written, because the reasoning still describes what the game should now be
able to drop.

Two things about the implementation that the note below did not anticipate.
`cmd_set_scissor` is gone -- that was no_gfx, and the backend moved to SDL3
before this was picked up, so the clip is built on `SDL_SetGPUScissor` instead.
And the scissor is state on the *render pass* rather than on the command
buffer, so it has to be re-applied every time a pass opens; `clear_background`
opens one every frame, which would otherwise drop the clip immediately.

Clips nest and intersect, so a list inside a panel cannot escape the panel.

Its absence shaped the game:

- both lists in the deck editor page instead of scroll, because a list drawn
  past the bottom of its panel would carry on over whatever is below it
- `decks.odin` carries roughly eighteen lines of paging bookkeeping that exist
  only to avoid needing a clip
- `Text_Field` documents "no scrolling when the text outruns the box" as a
  permanent limitation, which it is only because of this

Surfacing it makes paging a choice rather than a necessity, and gets scrolling
lists, clipped panels and long text fields in one change.

**Caveat.** Unlike everything below, this one is not purely additive. Exposing
it invites rewriting working paged screens as scrolling ones, which is a
behaviour change. Worth splitting: expose the clip, then convert one list and
see how it feels, rather than doing both as one sweep.

## 2. A button that draws and answers in one call

Matchbox has `Button`, `draw_button` and `mouse_over_button`. Using them means
three calls plus an `is_mouse_pressed` check, and the game wrote that wrapper
**four separate times**:

| | |
|---|---|
| `button_rect` | decks.odin -- takes a Rectangle, optional left-aligned label |
| `small_button` | decks.odin -- a fixed small size |
| `small_button_wide` | decks.odin -- an explicit size |
| `menu_button` | menu.odin -- centred in a width, advances a layout cursor |

Something along the lines of `button(rect, text) -> bool`, doing the hover
colour, the draw and the click together. Two things the present API cannot
express and all four wrappers wanted: **a label aligned left rather than
centred**, and **a size given at the call site**.

## 3. `draw_text_plate`

Text on a dark plate cut to fit it. Currently in the game's `ui.odin`.

It exists because white text drawn over card art landed on something pale often
enough to disappear, and there is no outline or drop shadow to fall back on.
Any game drawing text over artwork hits this; nothing about it is
card-specific.

Takes a top-left rather than a baseline, which is worth keeping -- every caller
is stacking boxes rather than typesetting.

## 4. A lazy sprite cache

`card_texture` and `view_closeup` in the game's `view.odin` are two hand-rolled
caches of the same shape: load a sprite from a path on demand, keep it under a
key, give it all back at teardown. One is a map; the other is a single slot that
evicts, because the full-size art is a megabyte a card and only one is ever on
screen.

Matchbox has `create_sprite` and `destroy_sprite` and nothing in between. A
`Sprite_Cache` keyed by any comparable type would serve any game with more art
than it wants resident at once.

## 5. A layout cursor, and a grid fitter

The `y: ^f32` pattern running through `menu_button`, `menu_field` and
`menu_note`: draw a thing, advance past it, centre it in a width. Small, and in
every screen the game has.

Worth pairing with the grid arithmetic from `deck_layout` in `decks.odin`: given
an area and a target item size, work out how many columns fit and what exact
item size fills the width. That is what stopped the card grid running off the
edge of a 13 inch laptop after being written on a 1920x1080 monitor.

## 6. Small things

- **`point_in_rect`** -- the game defines it; Matchbox has only
  `mouse_over_button`
- **A confirm-on-second-press button** -- the Delete then "Sure?" pattern from
  the deck list, for anything that cannot be undone
- **Hover dwell** -- "has the mouse rested here for N seconds", which is what
  drives the full-size card preview and keeps it from strobing across a grid

---

## Probably not

**The networking.** `proto/conn.odin` is non-blocking TCP with length-prefixed
CBOR framing, and it is genuinely reusable -- but taking it would commit
Matchbox to CBOR and to a particular message model. Worth it only if Matchbox is
meant to become a multiplayer framework rather than a rendering one.

**Everything else in the game.** The model/view package split, the screen enum,
the intent-and-snapshot shape: those are application architecture. What is
portable about them is the discipline, not the code.

---

## Already done

Listed so nobody goes looking for them. All of these started the same way --
written in the game, then moved:

- text input and key auto-repeat, and the `Text_Field` widget
- `draw_rect_border`, after `draw_outline`'s border turned out to be thicker on
  the long side of anything not square
- font ascent, descent and `measure_text`
- capping a new window to the display, so one never opens larger than the screen
- a console logger when the caller has not set one, and `gpu-report.txt` on a
  failed start
- filtering GPUs by what they support before scoring them
- scissor clipping, as `begin_clip` / `end_clip` -- see entry 1, which is kept
  in place because its argument is the case for what the game can now delete
