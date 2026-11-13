package vito

import "base:runtime"
import "core:fmt"
import sce "../sce"

// Output goes through sceClibPrintf: the Vita3K log window, or a tty/log
// plugin on a real console. Text is written with "%.*s", so Odin strings (which
// are not zero-terminated) are safe to pass.

// Writes a string as it is, no newline added.
write :: proc "contextless" (s: string) {
    if len(s) > 0 do sce.sceClibPrintf("%.*s", i32(len(s)), raw_data(s))
}

// print / println / printf format with core:fmt into a buffer on the stack
// (PRINT_BUFFER_SIZE bytes; longer output is cut off). They do not allocate.
PRINT_BUFFER_SIZE :: 1024

print :: proc(args: ..any, sep := " ") {
    buf: [PRINT_BUFFER_SIZE]byte
    write(fmt.bprint(buf[:], ..args, sep = sep))
}

println :: proc(args: ..any, sep := " ") {
    buf: [PRINT_BUFFER_SIZE]byte
    write(fmt.bprintln(buf[:], ..args, sep = sep))
}

printf :: proc(format: string, args: ..any) {
    buf: [PRINT_BUFFER_SIZE]byte
    write(fmt.bprintf(buf[:], format, ..args))
}

// ---------------------------------------------------------------
// Logger for context.logger, so core:log works (log.info, log.errorf, ...).
// ---------------------------------------------------------------
// Messages below this level are dropped. Change it at any time.
log_level: runtime.Logger_Level = .Debug

logger :: proc "contextless" () -> runtime.Logger {
    return {
        procedure    = logger_proc,
        data         = nil,
        lowest_level = .Debug,
        options      = {.Level, .Short_File_Path, .Line},
    }
}

logger_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string,
                    options: runtime.Logger_Options, location := #caller_location) {
    if level < log_level do return
    name: cstring
    switch {
    case level >= .Fatal:   name = "FATAL"
    case level >= .Error:   name = "ERROR"
    case level >= .Warning: name = "WARN "
    case level >= .Info:    name = "INFO "
    case:                   name = "DEBUG"
    }
    file := short_path(location.file_path)
    sce.sceClibPrintf("[%s] %.*s:%d: %.*s\n", name,
                      i32(len(file)), raw_data(file), location.line,
                      i32(len(text)), raw_data(text))
}

@(private)
short_path :: proc "contextless" (path: string) -> string {
    for i := len(path) - 1; i >= 0; i -= 1 {
        if path[i] == '/' || path[i] == '\\' do return path[i + 1:]
    }
    return path
}
