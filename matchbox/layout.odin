package matchbox

/*
	Layout
	------
	Two small things that every screen ends up writing for itself.

	`Layout` is a cursor down a column: ask it for the next box, put something
	in it, and it has already moved past. It replaces threading a `y: ^f32`
	through every draw call and adding the height back by hand at each one,
	which is where a stray `+ 4` hides for a week.

	`Grid` is the arithmetic for fitting items into an area: given a target
	item size, how many columns actually fit, and what size makes them fill the
	width exactly. That is what stops a grid laid out on a 1920x1080 monitor
	running off the edge of a 13 inch laptop.

	Neither draws anything. They hand back Rectangles, which is what button,
	draw_rect, Text_Field and everything else already take.
*/

// -----------------------------------------------------------------------
// Layout -- a cursor down a column
// -----------------------------------------------------------------------

Layout :: struct {
	x:       f32, // left edge of the column
	y:       f32, // where the next item goes; moves as items are taken
	width:   f32, // the column's width, which is what `centered` centres in
	spacing: f32, // gap left after each item
}

/*
	A column starting at `top_left`, `width` across, with `spacing` between
	items.

		l := matchbox.layout_make({40, 40}, 200, 8)

		if matchbox.button(matchbox.layout_next(&l, 42), "Play")     { ... }
		if matchbox.button(matchbox.layout_next(&l, 42), "Settings") { ... }
		matchbox.layout_space(&l, 16)
		matchbox.layout_text(&l, font, "v0.1")
*/
layout_make :: proc(top_left: [2]f32, width: f32, spacing: f32 = 0) -> Layout {
	return Layout{x = top_left.x, y = top_left.y, width = width, spacing = spacing}
}

/*
	The next box down the column, `height` tall, and the cursor moves past it.

	Full column width unless `width` is given, in which case the box is that
	wide and centred -- which is what a menu of buttons narrower than the
	column it sits in wants.

	The Rectangle comes back with pivot {0.5, 0.5}, so its `position` is the
	top-left corner. That is what everything laying content out wants to think
	in, and it means the result can go straight to button or draw_rect.
*/
layout_next :: proc(layout: ^Layout, height: f32, width: f32 = 0) -> Rectangle {
	w := width if width > 0 else layout.width
	x := layout.x + (layout.width - w) * 0.5

	rect := Rectangle{
		position = {x, layout.y},
		size     = {w, height},
		pivot    = {0.5, 0.5},
	}

	layout.y += height + layout.spacing
	return rect
}

// Leaves a gap. `spacing` is already applied after every item, so this is for
// the larger breaks between groups.
layout_space :: proc(layout: ^Layout, amount: f32) {
	layout.y += amount
}

/*
	Draws one line of text at the cursor and moves past it.

	The height taken is the font's ascent plus descent rather than the extent of
	these particular glyphs, so a stack of lines is evenly spaced whatever is
	written on them -- "Play" and "Play Card" advance by the same amount.
*/
layout_text :: proc(layout: ^Layout, font: ^Font, text: string, color: [4]f32 = {1, 1, 1, 1}) {
	line := font.ascent + font.descent

	draw_text(font, text, layout.x, layout.y + font.ascent, color)

	layout.y += line + layout.spacing
}

// Where the cursor has reached. Useful for sizing a panel to what went in it,
// or for feeding a scroll extent.
layout_height :: proc(layout: ^Layout, from_y: f32) -> f32 {
	return layout.y - from_y
}

// -----------------------------------------------------------------------
// Grid -- fitting items into an area
// -----------------------------------------------------------------------

Grid :: struct {
	origin:  [2]f32, // top-left of the first cell
	item:    [2]f32, // the size that actually fits, not the size asked for
	spacing: f32,
	cols:    int,
	rows:    int,
}

/*
	Works out how to fit `count` items of about `target` size into `area`.

	`target` is a wish, not an instruction. The number of columns is however
	many fit at that width, and then the item size is stretched or squeezed so
	those columns fill the area exactly -- leaving no ragged margin on the
	right, and no items hanging off the edge on a narrower screen than the one
	the numbers were picked on.

	The target's aspect ratio is kept, so cards stay card-shaped as they resize.

	**The item size does not depend on `count`.** It is worked out from how many
	columns the area holds, whether or not there are enough items to fill one.
	A grid of three where twelve would fit draws three items at their proper
	size with space to the right, rather than three enormous ones -- which is
	what a filtered list of anything looks like most of the time, and the count
	is exactly what changes as somebody types.

	Rows are however many the items need. Nothing here limits them to the
	area's height: a grid taller than its area is the normal case for something
	scrolling, and begin_clip is what confines it.
*/
grid_fit :: proc(area: Rectangle, target: [2]f32, count: int, spacing: f32 = 0) -> Grid {
	origin := rect_top_left(area)

	if count <= 0 || target.x <= 0 || target.y <= 0 || area.size.x <= 0 {
		return Grid{origin = origin, item = target, spacing = spacing}
	}

	// How many whole items of the wished-for width fit, counting the gaps
	// between them but not after the last one. At least one, or an area
	// narrower than a single item would come back with a grid of nothing.
	fit := max(1, int((area.size.x + spacing) / (target.x + spacing)))

	// Stretch to fill: the leftover that would have been a ragged right margin
	// is shared out across the columns the area holds. Across `fit` and not
	// across `cols`, so that having too few items to fill a row leaves a gap
	// on the right instead of inflating each of them to cover it.
	item_w := (area.size.x - spacing * f32(fit - 1)) / f32(fit)
	item_h := target.y * (item_w / target.x) // keep the shape

	// Only as many columns as there are items to put in them, so `rows` and
	// grid_cell agree about the shape of a short grid.
	cols := clamp(fit, 1, count)
	rows := (count + cols - 1) / cols

	return Grid{
		origin  = origin,
		item    = {item_w, item_h},
		spacing = spacing,
		cols    = cols,
		rows    = rows,
	}
}

/*
	The box for item `index`, filling left to right and then down.

	pivot {0.5, 0.5} again, so `position` is the top-left corner and the result
	goes straight to button, draw_rect or a sprite.
*/
grid_cell :: proc(grid: Grid, index: int) -> Rectangle {
	col := index % max(1, grid.cols)
	row := index / max(1, grid.cols)

	return Rectangle{
		position = {
			grid.origin.x + f32(col) * (grid.item.x + grid.spacing),
			grid.origin.y + f32(row) * (grid.item.y + grid.spacing),
		},
		size  = grid.item,
		pivot = {0.5, 0.5},
	}
}

// How tall the whole grid is, which is what a scroll extent is measured
// against and what a panel sized to its contents needs.
grid_height :: proc(grid: Grid) -> f32 {
	if grid.rows <= 0 do return 0
	return f32(grid.rows) * grid.item.y + f32(grid.rows - 1) * grid.spacing
}
