#+build freestanding arm32

package matchbox

import "base:runtime"

/*
	The logger the handhelds' start_runtime puts on the game's `context` (see logger.odin for why). Debug messages are
	left out: every one is a line on a screen or in a file that has to be written on a console with little to spare.
	`print` is each target's own (util_3ds_..., util_vita_...), so the same `log.info` shows on the 3DS's bottom screen and
	in the Vita's log file without the game saying which
*/
create_handheld_logger :: proc() -> runtime.Logger {
	return runtime.Logger{procedure = write_log_line, data = nil, lowest_level = .Info, options = {}}
}

@(private = "file")
write_log_line :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	print(get_log_level_tag(level), text)
}
