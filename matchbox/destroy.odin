package matchbox

/*
	destroy
	-------
	One name for giving anything back.

	Every type that owns something has its own destroy_ procedure, and they are
	all still here and all still callable -- this only saves the caller from
	having to remember which of them goes with which type, and from having to
	change the call when the type changes:

		matchbox.destroy(&player)
		matchbox.destroy(&explosion)
		matchbox.destroy(&name_field)
		matchbox.destroy(&art_cache)
		matchbox.destroy(&gameboy_screen)
		matchbox.destroy(&opened_png)

	Odin picks by the type of the argument, so getting it wrong is a compile
	error rather than a leak, which is the whole point.

	What is *not* in here is `cleanup`, which takes Matchbox itself down. That
	one stays under its own name deliberately: it is called once, at the end, and
	it is not "one more thing to free" -- everything else in this group stops
	working after it.
*/

destroy :: proc {
	destroy_mesh,
	destroy_sprite,
	destroy_animated_sprite,
	destroy_animation_clip,
	destroy_parallax,
	destroy_font,
	destroy_sound,
	destroy_pixel_buffer,
	destroy_model,
	destroy_animator,
	destroy_skybox,
	destroy_render_target,
	destroy_image,
	destroy_text_field,
	destroy_sprite_cache,
	destroy_animation_source,
}
