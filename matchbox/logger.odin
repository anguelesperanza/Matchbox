package matchbox

import "base:runtime"

/*
	Logging
	=======
	`log.info`, `log.errorf` and the rest of core:log write to `context.logger`, and Matchbox's own code uses them (a
	full animation queue, a missing animation name, a font that does not fit its atlas). On PC the game installs
	core:log's console logger. On the 3DS and Vita there is none to install (`create_console_logger` is not in core:log
	for the handhelds: it needs an operating system's standard output), so without one every message is dropped. The
	handhelds therefore give the game a logger already installed on its `context` (start_runtime in each backend,
	logger_handheld_freestanding_arm32.odin) that sends each message to `print`, which is where those targets show
	text: the 3DS's bottom screen and the emulator's log, the Vita's log window and its log file.
*/

/*The word a line is tagged with: "[ERROR] text". Shared so the format is tested on PC, though only the handhelds log this way*/
get_log_level_tag :: proc(level: runtime.Logger_Level) -> string {
	switch {
	case level >= .Fatal: return "[FATAL]"
	case level >= .Error: return "[ERROR]"
	case level >= .Warning: return "[WARN]"
	case level >= .Info: return "[INFO]"
	}
	return "[DEBUG]"
}
