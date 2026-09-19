package guidebook

/*
	Guidebook
	=========
	An event system to trigger events

	How it works (currenlty)

	Events are a struct that contain the following:
	A) events position -> [3]f32,
	B) can_trigger -> bool,
	C) event_proc -> function pointer to the function that this event will trigger

	Right now; events are considered areas that the player can enter and trigger an action to happen
	Still researching different ways to handle events; might change to a pub/sub model, might keep as is

	This is still very much in early POC
*/

import "core:math"
import "core:math/linalg"

Event :: struct {
	position:[3]f32,
	can_trigger:bool,
	event_proc:proc(Event),
}

/*Checks if a players position overlaps with the event_position to be able to trigger an event*/
is_event_in_reach :: proc(event_position:  [3]f32, player_position: [3]f32,	player_yaw: f32, reach: f32 = 1.0, cone_degrees: f32 = 120) -> bool {
	d := [2]f32{event_position.x - player_position.x, event_position.z - player_position.z}

	distance2 := linalg.dot(d, d)
	if distance2 > reach * reach do return false

	// Standing exactly on it: there is no direction to face, and normalising a
	// zero vector is a NaN that fails every comparison after it -- so the cone
	// would report "not looking at it" for the one case that is unarguably close
	// enough.
	if distance2 == 0 do return true

	// (cos, sin) across x and z, which is the yaw convention `walk_direction`
	// uses, so a rig's `yaw` or `facing` goes in here untouched.
	forward := [2]f32{math.cos(player_yaw), math.sin(player_yaw)}
	toward  := d / math.sqrt(distance2)

	return linalg.dot(toward, forward) >= math.cos(math.to_radians(cone_degrees * 0.5))
}


