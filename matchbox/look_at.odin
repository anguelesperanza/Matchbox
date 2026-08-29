package matchbox

import "core:math"

// -----------------------------------------------------------------------
// Systems -- Look At
// -----------------------------------------------------------------------

// Which side of the sprite image is its forward-facing direction at rotation 0.
SpriteForward :: enum {
    Top,    // top of the image faces the target  (default — suits top-down sprites)
    Right,  // right side of the image faces the target
    Bottom, // bottom of the image faces the target
    Left,   // left side of the image faces the target
}

// Returns the angle (radians) needed to face from a point toward target.
// forward controls which side of the sprite is treated as its forward direction.
look_at_point :: proc(from: [2]f32, target: [2]f32, forward: SpriteForward = .Top) -> f32 {
	direction := target - from
	offset: f32
	switch forward {
	case .Top:    offset =  math.PI / 2
	case .Right:  offset =  0
	case .Bottom: offset = -math.PI / 2
	case .Left:   offset =  math.PI
	}
	return math.atan2(direction.y, direction.x) + offset
}

// Returns the angle (radians) needed to face a sprite's visual center toward target.
// Uses position + pivot * size so rotation is always computed from the correct origin.
// forward controls which side of the sprite is treated as its forward direction.
look_at_sprite :: proc(sprite: Sprite, target: [2]f32, forward: SpriteForward = .Top) -> f32 {
	center := sprite.position + sprite.pivot * sprite.size
	return look_at_point(center, target, forward)
}

// The angle that points something at a target, given either a plain position
// or a sprite -- see the two procedures above for which side counts as forward.
look_at :: proc { look_at_point, look_at_sprite }
