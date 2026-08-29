package matchbox


import "core:fmt"
import "core:os"
import "core:encoding/json"

/*This file contains the code needed for loading tiled levels
This was typed by hand, based on a Go generated quicktype output*/

TiledObjectLayer :: struct {
	height:f32,
	id:int,
	name:string,
	opacity:int,
	roation:f32,
	type:string,
	visible:bool,
	width:f32,
	x:f32,
	y:f32,
}

TiledLayer :: struct {
	data:[]int,
	objects:[]TiledObjectLayer,
	height:int,
	id:int,
	name:string,
	opacity:int,
	type:string,
	visible:bool,
	width:int,
	x:f32,
	y:f32,
	draworder:string,
}

TiledTileset :: struct {
	firstgrid:int,
	source:string,
}

Tiled :: struct {
	compressionlevel:int,
	height:int,
	infinite:bool,
	layers:[]TiledLayer,
	nextlayerid:int,
	nextobjectid:int,
	orientation:string,
	tiledversion:string,
	tileheight:int,
	tilesets:[]TiledTileset,
	tilewidth:int,
	type:string,
	width:int
}

/*
	Reads a Tiled `.tmj` map off disk and parses it.

	`core:os` rather than `read_entire_file`, so unlike the model loader this
	one does **not** work from inside an Android apk. Returns a zeroed `Tiled`
	and logs on a file it cannot read or parse.
*/
tiled_load_level :: proc(level:string)  -> Tiled {
	data, data_err := os.read_entire_file(level, context.allocator)
	if data_err != nil {
		fmt.eprintln("Failed to load level.", data_err)
		return {}
	}
	defer delete(data)

	tiled:Tiled
	unmarshal_err := json.unmarshal(data, &tiled)

	if unmarshal_err != nil {
		fmt.eprintln("Failed to unmarshal level.", unmarshal_err)
		return {}
	}

	return tiled
}


// Returns the TiledLayer whose name matches `name`.
// The second return value is false if no layer with that name exists.
tiled_find_layer :: proc(level: Tiled, name: string) -> (TiledLayer, bool) {
	for layer in level.layers {
		if layer.name == name {
			return layer, true
		}
	}
	return {}, false
}

// Returns the object list from the layer whose name matches `layer_name`.
// The second return value is false if no layer with that name exists.
tiled_find_objects :: proc(level: Tiled, layer_name: string) -> ([]TiledObjectLayer, bool) {
	for layer in level.layers {
		if layer.name == layer_name {
			return layer.objects, true
		}
	}
	return nil, false
}

// Returns the world-space position for a sprite spawned at the first object
// in the layer named `layer_name`. The raw Tiled coordinates are multiplied
// by `scale` and then shifted left/up by half `sprite_size` so the sprite is
// centered on the spawn point. Returns {0, 0} if the layer or its first
// object cannot be found.
tiled_get_spawn_position :: proc(level: Tiled, layer_name: string, scale: f32, sprite_size: [2]f32) -> [2]f32 {
	for layer in level.layers {
		if layer.name == layer_name && len(layer.objects) > 0 {
			pos := [2]f32{layer.objects[0].x, layer.objects[0].y} * scale
			pos -= sprite_size * 0.5
			return pos
		}
	}
	return {0, 0}
}

/*
	Stops a body at the first solid object in its way horizontally, adjusting
	`dx` in place.

	Horizontal and vertical are resolved by separate procedures, called one
	after the other, because doing both at once against a grid catches a body on
	seams between tiles that are flush with each other -- the classic "snagging
	while running along a flat floor" bug.
*/
tiled_resolve_x_collision :: proc(body: ^Body, collisions: []TiledObjectLayer, dx: ^f32, scale: f32) {
	p  := body.bounding_box_padding
	bb := sprite_bounds(body)

	for object in collisions {
		object_bounds := [4]f32{object.x, object.y, object.x + object.width, object.y + object.height} * scale
		if bounding_box_collision_check(bb, object_bounds) {
			if dx^ > 0 {
				body.position.x = object_bounds[0] - body.size.x + p[2]
				dx^ = 0
			} else if dx^ < 0 {
				body.position.x = object_bounds[2] - p[0]
				dx^ = 0
			}
			bb = sprite_bounds(body)
		}
	}
}

/*
	The vertical half of the pair, adjusting `vy` in place.

	Uses `bounding_box_contact_check` where the horizontal one uses
	`bounding_box_collision_check`: a body resting exactly on a floor is in
	contact with it rather than overlapping it, and an overlap test reports
	"standing on nothing" on the frame it lands.
*/
tiled_resolve_y_collision :: proc(body: ^Body, collisions: []TiledObjectLayer, vy: ^f32, scale: f32) {
	p  := body.bounding_box_padding
	bb := sprite_bounds(body)

	for object in collisions {
		object_bounds := [4]f32{object.x, object.y, object.x + object.width, object.y + object.height} * scale
		if bounding_box_contact_check(bb, object_bounds) {
			if vy^ >= 0 {
				body.position.y = object_bounds[1] - body.size.y + p[3]
				vy^ = 0
				body.on_ground = true
			} else if vy^ < 0 {
				body.position.y = object_bounds[3] - p[1]
				vy^ = 0
			}
			bb = sprite_bounds(body)
		}
	}
}

// -----------------------------------------------------------------------
// Drawing
// -----------------------------------------------------------------------

/*Draw tiled layer to the screen.
NEEDS IMPROVEMENT: need to add batch drawing once I learn how*/
draw_tiled_layer :: proc(layer:TiledLayer, tileset:Sprite, tile_width:int, tile_height:int) {

	offset:[2]f32 = {cast(f32)layer.x, cast(f32)layer.y} // get the initial x,y pos for the layer to know where to draw
	
	for tile, index in layer.data {
		if offset.x >= cast(f32)layer.width {
			offset.x = 0
			offset.y += 1
		}
		
		if tile == 0 { // No tile in level data, so increase offset and skip
			offset.x += 1
			continue
		}


		t := tileset // Create a copy of the tileset sprite only for tiles that need to be rendered
		t.position = {offset.x * cast(f32)tile_width * t.scale, offset.y * cast(f32)tile_height * t.scale}
		t.size = {cast(f32)tile_width, cast(f32)tile_height} * t.scale


		tileset_cols := cast(int)(tileset.size.x / tileset.scale) / tile_width
		local_index  := cast(int)tile - 1
		tile_col     := local_index % tileset_cols
		tile_row     := local_index / tileset_cols

		src_x := cast(f32)(tile_col * tile_width)
		src_y := cast(f32)(tile_row * tile_height)

		t.uv_min = {src_x / (tileset.size.x / tileset.scale), src_y / (tileset.size.y / tileset.scale)}
		t.uv_max = {(src_x + cast(f32)tile_width) / (tileset.size.x / tileset.scale ), (src_y + cast(f32)tile_height) / (tileset.size.y / tileset.scale)}

		draw_sprite(t)

		offset.x += 1
	}
}

/*Draw every visible tile layer in the level.

Layers are drawn in Tiled's layer order: the JSON `layers` array is ordered
bottom -> top, so later layers in the array render on top of earlier ones.
Non-tile layers (object groups such as collisions, spawns, and item markers)
and layers hidden in Tiled are skipped.

Tile width/height are taken from the level, so callers don't have to pass them.
Use this instead of calling draw_tiled_layer per layer to guarantee the in-game
layering matches what you see in the Tiled editor.*/
draw_tiled_layers :: proc(level: Tiled, tileset: Sprite) {
	for layer in level.layers {
		if layer.type != "tilelayer" do continue
		if !layer.visible do continue
		draw_tiled_layer(layer, tileset, level.tilewidth, level.tileheight)
	}
}

