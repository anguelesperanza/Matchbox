package ui_example

/*
	The three things a card game kept writing for itself:

	  button           draws, hovers and answers a click in one call
	  draw_text_plate  text on a plate, so it survives landing on pale artwork
	  Sprite_Cache     art loaded on demand and evicted when it is not wanted

	The cache here has a limit of one, which is the shape the game's full-size
	card view needed: the art is far too big to keep all of it resident, and
	only one is ever on screen. Watch the resident count as you switch cards --
	it never goes above one, and switching back reloads.
*/

import "core:fmt"

import "../../matchbox"

Card :: enum {
	EMBER,
	FROST,
	BRAMBLE,
}

CARD_PATH := [Card]string{
	.EMBER   = "art/ember.png",
	.FROST   = "art/frost.png",
	.BRAMBLE = "art/bramble.png",
}

CARD_NAME := [Card]string{
	.EMBER   = "Ember",
	.FROST   = "Frost",
	.BRAMBLE = "Bramble",
}

PANEL :: [4]f32{0.20, 0.20, 0.26, 1}

main :: proc() {
	matchbox.init("UI", 760, 520)
	defer matchbox.cleanup()

	font := &matchbox.mbi.font

	// One slot. Selecting a different card evicts the one before it.
	cache := matchbox.sprite_cache_make(Card, limit = 1)
	defer matchbox.sprite_cache_destroy(&cache)

	selected := Card.EMBER
	loads    := 0

	deleted: bool
	del:     matchbox.Confirm_Button
	preview: matchbox.Hover

	for matchbox.is_running() {
		matchbox.poll_events()

		matchbox.begin_drawing()
		matchbox.clear_background({0.09, 0.09, 0.11, 1})

		// ---- buttons -----------------------------------------------------
		matchbox.draw_text(font, "centred", 40, 46, matchbox.WHITE)

		for card, i in Card {
			rect := matchbox.Rectangle{
				position = {40, 60 + f32(i) * 52},
				size     = {180, 42},
				color    = PANEL,
				pivot    = {0.5, 0.5},
			}

			if matchbox.button(rect, CARD_NAME[card]) {
				if card != selected {
					selected = card
					loads += 1
				}
			}
		}

		// The same buttons, labels against the left edge. A stacked column
		// reads better this way -- centred labels leave both edges ragged.
		matchbox.draw_text(font, "left aligned", 250, 46, matchbox.WHITE)

		left_style := matchbox.BUTTON_STYLE
		left_style.align = .LEFT

		for card, i in Card {
			rect := matchbox.Rectangle{
				position = {250, 60 + f32(i) * 52},
				size     = {180, 42},
				color    = PANEL,
				pivot    = {0.5, 0.5},
			}

			if matchbox.button(rect, CARD_NAME[card], left_style) {
				if card != selected {
					selected = card
					loads += 1
				}
			}
		}

		// ---- confirm on second press --------------------------------------
		if matchbox.button_confirm(&del,
			{position = {40, 330}, size = {180, 42}, color = PANEL, pivot = {0.5, 0.5}},
			"Delete deck", "Sure?") {
			deleted = true
		}

		if deleted do matchbox.draw_text(font, "deleted", 250, 358, matchbox.RED)

		// ---- cached art, with plates over it -----------------------------
		art_rect := matchbox.Rectangle{position = {470, 60}, size = {240, 336}, pivot = {0.5, 0.5}}

		if sprite := matchbox.sprite_cache_get(&cache, selected, CARD_PATH[selected], 2); sprite != nil {
			art := sprite^ // a copy: position is ours, the cache keeps its own
			art.position = art_rect.position
			art.pivot    = {0.5, 0.5}
			matchbox.draw_sprite(art)

			// Straight onto the art, which is the case the plate exists for.
			size := matchbox.draw_text_plate(font, CARD_NAME[selected], {478, 68})
			matchbox.draw_text_plate(font, "cost 3", {478, 68 + size.y + 4})
		}

		// ---- hover dwell ---------------------------------------------------
		// Rest the pointer on the card rather than sweeping over it. A preview
		// that opened on plain hover would flicker its way across a grid.
		if matchbox.hover_dwell(&preview, art_rect) {
			matchbox.draw_text_plate(font, "closeup", {478, 350})
		} else if p := matchbox.hover_progress(&preview); p > 0 {
			matchbox.draw_rect({
				position = {478, 384},
				size     = {224 * p, 6},
				color    = {1, 1, 1, 0.7},
				pivot    = {0.5, 0.5},
			})
		}

		matchbox.draw_text(font,
			fmt.tprintf("resident %d of %d   loads %d",
				matchbox.sprite_cache_len(&cache), len(Card), loads),
			40, 250, matchbox.WHITE)

		matchbox.draw_text(font, "click a name to switch card", 40, 285, matchbox.WHITE)

		matchbox.end_drawing()
	}
}
