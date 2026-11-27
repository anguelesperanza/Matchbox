package matchbox

/*
	Frees whatever it is given: `matchbox.destroy(&x)` or `matchbox.destroy(x)` resolves to the
	destroy_x for that type. Every public destroy_x joins this group.

	One group for every target, not one per backend. It used to be written out three times
	(util_windows, util_3ds_, util_vita_), and the handhelds' copies held only destroy_audio, so
	a game that freed a sprite or a parallax layer with `destroy` built on PC and failed on the
	3DS with "Cannot assign value of type 'Parallax_Layer' to 'Audio'". A target that has
	nothing to free for a type still declares its destroy_x, empty, so this stays the same list
	everywhere
*/
destroy :: proc {
	destroy_audio,
	destroy_mesh,
	destroy_model,
	destroy_texture,
	destroy_render_target,
	destroy_sprite,
	destroy_animation_clip,
	destroy_parallax,
	destroy_font,
	destroy_skybox,
}
