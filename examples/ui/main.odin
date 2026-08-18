package ui_example

/*
	Everything in ui.odin, on one screen.

	  button              draws, hovers and answers a click in one call
	  button_enabled_if   the same button, dimmed and deaf
	  button_confirm      asks first, for anything that cannot be undone
	  hover_dwell         the pointer resting on something rather than crossing it
	  draw_text_plate     text on a plate, so it survives landing on pale artwork
	  Text_Field          somewhere to type, with its label above it
	  Dropdown            pick one of a list, opening out over everything else
	  context_menu        the same list, hanging off the pointer instead
	  Scroll_View         a list taller than the panel it is in
	  draw_tooltip        a plate beside the cursor, kept on screen
	  Status_Line         a short message with a severity colour
	  Modal               a full-screen dim with something centred on top
	  Slider              pick a number by dragging, in f32 or whole numbers
	  draw_progress       a bar from 0 to 1
	  Sprite_Cache        art loaded on demand and evicted when it is not wanted

	The thing worth understanding here is **order**, because three of these come
	in two halves and it is not decoration. Drawing is immediate, so whatever
	opens out over the screen has to be drawn *last*; but every widget tests the
	mouse for itself, so the same widget has to take the pointer *first*, or the
	things underneath answer clicks that were meant for it. Hence:

		modal_begin        early -- takes the pointer for the frame
		dropdown           early -- the closed box, and all of the list's input
		context_menu       early -- the open menu's input
		... the rest of the screen ...
		dropdown_overlay   late  -- the open list, over everything
		draw_tooltip       late
		modal_overlay      last  -- the dim, and it hands the pointer back

	`capture_mouse` only reaches widgets that run *after* it. The "underneath"
	button below is there to prove it: open the dropdown and it neither lights
	up nor answers.

	Things to try:

	  - scroll the deck list with the wheel, and drag its bar
	  - right-click a deck near the bottom edge, so its menu flips upwards
	  - rest the pointer on a deck to read the hint, and take it to a corner
	  - open the preview and click the dim to dismiss it
	  - type a name, and watch Save come alive
	  - switch cards and watch the cache: resident never goes above one

	See examples/shapes for the drawing -- lines, circles, triangles, sprite
	tints, and text at more than one size.
*/

import "core:fmt"

import mb "../../matchbox"

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

ACTIONS := []string{"Rename", "Duplicate", "Export", "Delete"}

BG     :: [4]f32{0.09, 0.09, 0.11, 1}
PANEL  :: [4]f32{0.14, 0.14, 0.18, 1}
BUTTON :: [4]f32{0.20, 0.20, 0.26, 1}
ROW    :: [4]f32{0.19, 0.19, 0.25, 1}
LABEL  :: [4]f32{0.62, 0.64, 0.72, 1}

// Three columns, so nothing here has to be found by counting pixels.
COL_A   :: f32(30)  // the deck list
COL_B   :: f32(400) // buttons and the dropdown
COL_C   :: f32(660) // art, and the things drawn over it
COL_A_W :: f32(340)
COL_B_W :: f32(220)

ROW_H   :: f32(34)
ROW_GAP :: f32(4)

Deck :: struct {
	name:  string,
	cards: int,
}

main :: proc() {
	mb.init("UI", 1200, 800)
	defer mb.cleanup()

	font := &mb.mbi.font

	// One slot. Selecting a different card evicts the one before it -- the
	// shape a full-size card view needs, where the art is far too big to keep
	// all of it resident and only one is ever on screen.
	cache := mb.sprite_cache_make(Card, limit = 1)
	defer mb.destroy(&cache)

	decks: [dynamic]Deck
	defer delete(decks)
	for i in 0 ..< 24 {
		append(&decks, Deck{name = fmt.aprintf("Deck %d", i + 1), cards = 30 + i})
	}
	defer for d in decks do delete(d.name)

	name: mb.Text_Field
	name.label       = "Deck name"
	name.placeholder = "untitled"
	name.max_bytes   = 40
	defer mb.destroy(&name)

	list:    mb.Scroll_View
	grey:    mb.Slider
	fade:    mb.Slider
	pick:    mb.Dropdown
	menu:    mb.Dropdown
	preview: mb.Modal
	note:    mb.Status_Line
	dwell:   mb.Hover
	del:     mb.Confirm_Button

	selected  := Card.EMBER
	greyness  := f32(0)
	opacity   := 100
	loads     := 0
	covered  := 0 // presses of the button the open list sits on top of
	menu_on  := -1
	hovered  := -1
	deleted:    bool

	mb.set_status(&note, "right-click a deck for its menu", .INFO)

	for mb.is_running() {
		mb.poll_events()

		h := f32(mb.mbi.height)

		// Before anything else: while the modal is up, nothing underneath may
		// answer a click. Capture only reaches what runs after it.
		blocked := mb.modal_begin(&preview)

		mb.begin_drawing()
		mb.clear_background(BG)

		heading :: proc(font: ^mb.Font, text: string, at: [2]f32) {
			mb.draw_text(font, text, at.x, at.y + font.ascent, LABEL)
		}

		// ---- a field, with its label above it ------------------------------
		// The label is not part of the field's rectangle -- that stays the box,
		// so the hit test and the caret are untouched by adding one, which is
		// why placing it goes through text_field_place.
		mb.text_field_place(&name, {COL_A, 24}, {COL_A_W, 36})
		name.rectangle.color = PANEL

		if !blocked do mb.update_text_field(&name)
		mb.draw_text_field(&name)

		// ---- the dropdown, early --------------------------------------------
		heading(font, "dropdown", {COL_B, 470})

		names: [len(Card)]string
		for card, i in Card do names[i] = CARD_NAME[card]

		if mb.dropdown(&pick,
			{position = {COL_B, 494}, size = {COL_B_W, 42}, color = BUTTON, pivot = {0.5, 0.5}},
			names[:]) {
			selected = Card(pick.selected)
			loads += 1
		}

		// ---- the context menu's input, also early ----------------------------
		// So a click landing on an open menu does not also press the deck row
		// underneath it.
		if choice, picked := mb.context_menu(&menu, ACTIONS); picked {
			mb.set_status(&note,
				fmt.tprintf("%s on %s", ACTIONS[choice], decks[menu_on].name),
				.BAD if choice == 3 else .GOOD, 3)
		}

		// ---- the scrolling deck list -----------------------------------------
		heading(font, "decks -- wheel, or right-click one", {COL_A, 100})

		panel := mb.Rectangle{
			position = {COL_A, 124},
			size     = {COL_A_W, h - 124 - 130},
			color    = PANEL,
			pivot    = {0.5, 0.5},
		}
		mb.draw_rect(panel)

		content := f32(len(decks)) * (ROW_H + ROW_GAP)
		origin  := mb.begin_scroll(&list, panel, content)

		hovered = -1
		row_style := mb.BUTTON_STYLE
		row_style.align = .LEFT

		for deck, i in decks {
			row := mb.Rectangle{
				position = {origin.x + 8, origin.y + f32(i) * (ROW_H + ROW_GAP)},
				size     = {panel.size.x - 16 - mb.SCROLLBAR_WIDTH, ROW_H},
				color    = ROW,
				pivot    = {0.5, 0.5},
			}

			if mb.button(row, deck.name, row_style) {
				mb.set_status(&note, fmt.tprintf("opened %s", deck.name), .INFO, 2)
			}

			// Hit-testing by hand, so it has to ask about capture itself.
			// `button` does that for you; this does not.
			if mb.mouse_over_rect(row) && !mb.mouse_captured() {
				hovered = i

				if mb.is_mouse_pressed(.RIGHT) {
					menu_on = i
					mb.open_context_menu(&menu, mb.get_mouse_position(), {150, 30})
				}
			}
		}

		mb.end_scroll(&list)

		// ---- how far down the list is, as a bar --------------------------------
		through: f32
		if m := mb.scroll_max(&list); m > 0 do through = list.offset / m

		heading(font, "scrolled", {COL_A, h - 84})
		mb.draw_progress_labelled(
			{position = {COL_A, h - 58}, size = {COL_A_W, 22}, pivot = {0.5, 0.5}},
			through, mb.progress_percent(through, context.temp_allocator),
		)

		// ---- buttons -----------------------------------------------------------
		heading(font, "centred", {COL_B, 24})

		for card, i in Card {
			rect := mb.Rectangle{
				position = {COL_B, 48 + f32(i) * 52},
				size     = {COL_B_W, 42},
				color    = BUTTON,
				pivot    = {0.5, 0.5},
			}

			if mb.button(rect, CARD_NAME[card]) {
				if card != selected {
					selected = card
					loads += 1
				}
			}
		}

		// The same buttons with their labels against the left edge, which is how
		// a stacked column reads -- centred labels leave both edges ragged. The
		// card already selected is disabled, which is the case `button` had no
		// answer for: it does not light up, it does not answer, and it dims
		// whatever colour it was handed rather than needing a second one picked.
		heading(font, "left aligned, and disabled", {COL_B, 214})

		left_style := mb.BUTTON_STYLE
		left_style.align = .LEFT

		for card, i in Card {
			rect := mb.Rectangle{
				position = {COL_B, 238 + f32(i) * 52},
				size     = {COL_B_W, 42},
				color    = BUTTON,
				pivot    = {0.5, 0.5},
			}

			style := left_style
			style.disabled = card == selected

			if mb.button(rect, CARD_NAME[card], style) {
				selected = card
				loads += 1
			}
		}

		// ---- confirm on second press --------------------------------------------
		if mb.button_confirm(&del,
			{position = {COL_B, 400}, size = {COL_B_W, 42}, color = BUTTON, pivot = {0.5, 0.5}},
			"Delete deck", "Sure?") {
			deleted = true
		}
		if deleted do mb.draw_text(font, "deleted", COL_B, 458 + font.ascent, mb.RED)

		// Sits under the open list on purpose. Clicking an option must not press
		// this, and while the list is open it must not even light up.
		if mb.button(
			{position = {COL_B, 550}, size = {COL_B_W, 42}, color = BUTTON, pivot = {0.5, 0.5}},
			"underneath") {
			covered += 1
		}

		mb.draw_text(font, fmt.tprintf("underneath pressed %d", covered),
			COL_B, 606 + font.ascent, LABEL)

		// A name is needed before there is anything to save under.
		typed := len(mb.text_field_string(&name)) > 0

		if mb.button({position = {COL_B, 640}, size = {COL_B_W, 42}, color = BUTTON, pivot = {0.5, 0.5}},
			"Save" if typed else "Save (needs a name)", mb.button_enabled_if(typed)) {
			mb.set_status(&note, fmt.tprintf("saved as %s", mb.text_field_string(&name)), .GOOD, 3)
		}

		// ---- sliders ----------------------------------------------------------
		// Called here, drawn lower down the screen. In immediate mode the call
		// order is the *input* order and the rectangle is only geometry, so
		// taking these before the art is drawn means a drag shows up on the same
		// frame rather than the next one.
		mb.slider(&grey, {position = {COL_C, 524}, size = {240, 20}, pivot = {0.5, 0.5}},
			&greyness, 0, 1)
		mb.slider_int(&fade, {position = {COL_C, 588}, size = {240, 20}, pivot = {0.5, 0.5}},
			&opacity, 0, 100)

		// ---- cached art, with plates over it --------------------------------------
		heading(font, "cached art, and plates over it", {COL_C, 24})

		art_rect := mb.Rectangle{position = {COL_C, 48}, size = {240, 336}, pivot = {0.5, 0.5}}

		if sprite := mb.sprite_cache_get(&cache, selected, CARD_PATH[selected], 2); sprite != nil {
			art := sprite^ // a copy: position is ours, the cache keeps its own
			art.position   = art_rect.position
			art.size       = art_rect.size
			art.pivot      = {0.5, 0.5}
			art.desaturate = greyness
			art.tint       = {1, 1, 1, f32(opacity) / 100}
			mb.draw_sprite(art)

			// Straight onto the art, which is the case the plate exists for.
			size := mb.draw_text_plate(font, CARD_NAME[selected], {COL_C + 8, 56})
			mb.draw_text_plate(font, "cost 3", {COL_C + 8, 56 + size.y + 4})
		}

		// Rest the pointer on the card rather than sweeping over it. A preview
		// that opened on plain hover would flicker its way across a grid.
		if mb.hover_dwell(&dwell, art_rect) {
			mb.draw_text_plate(font, "closeup", {COL_C + 8, 338})
		} else if p := mb.hover_progress(&dwell); p > 0 {
			mb.draw_progress({position = {COL_C + 8, 372}, size = {224, 6}, pivot = {0.5, 0.5}}, p)
		}

		mb.draw_text(font,
			fmt.tprintf("resident %d of %d   loads %d",
				mb.sprite_cache_len(&cache), len(Card), loads),
			COL_C, 400 + font.ascent, LABEL)

		if mb.button({position = {COL_C, 436}, size = {240, 42}, color = BUTTON, pivot = {0.5, 0.5}},
			"Preview top deck") {
			mb.open_modal(&preview)
		}

		// The labels go where the sliders were placed. draw_progress drew this
		// shape already and would not take input; these are the other half of it.
		heading(font, fmt.tprintf("desaturate  %.2f", greyness), {COL_C, 500})
		heading(font, fmt.tprintf("opacity  %d%%", opacity), {COL_C, 564})

		// ---- the status line --------------------------------------------------------
		mb.draw_status(&note, {COL_C, h - 58})

		// ---- and now the things that go over the top ----------------------------------
		// A hint on the deck being rested on. Late, so it is over the list.
		if hovered >= 0 && mb.hover_dwell(&dwell, list.area) && !blocked {
			deck := decks[hovered]
			mb.draw_tooltip(fmt.tprintf(
				"%s holds %d cards. Right-click for rename, duplicate, export and delete.",
				deck.name, deck.cards,
			))
		}

		// The open lists, over everything drawn after their boxes.
		mb.dropdown_overlay(&pick, names[:])
		mb.dropdown_overlay(&menu, ACTIONS)

		// The modal, last of all. It hands the pointer back as it draws, so the
		// button inside it answers normally -- except on the frame it opened,
		// where the press that opened it is still live and belongs to nothing
		// in here.
		if box, open := mb.modal_overlay(&preview, {360, 280}); open {
			card := box
			card.color = PANEL
			mb.draw_rect(card)
			mb.draw_rect_border(card, {0.4, 0.42, 0.5, 1}, 2)

			top := mb.rect_top_left(box)
			mb.draw_text(font, decks[0].name, top.x + 16, top.y + 20 + font.ascent, mb.WHITE)

			mb.draw_text_wrapped(font,
				"Drawn last and centred, over a dim that covers everything. " +
				"Click the dim to put it away.",
				{top.x + 16, top.y + 60}, box.size.x - 32, LABEL)

			if mb.button({position = {top.x + 16, top.y + box.size.y - 56},
			              size = {120, 40}, color = BUTTON, pivot = {0.5, 0.5}}, "Close") {
				mb.close_modal(&preview)
			}

			// After the content, so the button in the corner gets the click first.
			if mb.modal_dismissed(box) do mb.close_modal(&preview)
		}

		mb.end_drawing()
		free_all(context.temp_allocator)
	}
}
