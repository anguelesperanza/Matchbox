package vito

import "base:runtime"
import sce "../sce"

// What happens when `assert` fails or `panic` is called.
//
// Odin's default handler on this target prints nothing. This one:
//   1. prints the location and message through sceClibPrintf,
//   2. appends the same line to PANIC_LOG_PATH, because a real console has no
//      log window to look at,
//   3. traps. The Vita then shows its crash screen (C2-12828-1) and writes a
//      core dump whose PC is inside this handler; the message from steps 1
//      and 2 says where the assertion really was.
//
// Bounds-check and nil-dereference failures do NOT come through here. The
// runtime handles those itself and traps straight away with no message; read
// the core dump for those (docs/getting-started.md, "Debugging a crash").

// Set to "" to turn the file off. ux0:data always exists.
panic_log_path: cstring = "ux0:data/vito_panic.log"

// What to do after reporting. .Trap gives a crash screen and a core dump;
// .Exit closes the app quietly back to the LiveArea.
Panic_Action :: enum {
    Trap,
    Exit,
}
panic_action: Panic_Action = .Trap

assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
    line: [512]u8
    n := sce.sceClibSnprintf(raw_data(line[:]), len(line), "%.*s(%d:%d) %.*s: %.*s%s%.*s\n",
        i32(len(loc.file_path)), raw_data(loc.file_path), loc.line, loc.column,
        i32(len(loc.procedure)), raw_data(loc.procedure),
        i32(len(prefix)), raw_data(prefix),
        cstring(": ") if len(message) > 0 else cstring(""),
        i32(len(message)), raw_data(message))
    n = clamp(n, 0, i32(len(line) - 1))
    sce.sceClibPrintf("%s", cstring(raw_data(line[:])))

    // (Checked by hand: comparing a cstring with "" trips an Odin compiler
    // assertion on this target, "missing procedure 'cstring_to_string'".)
    if panic_log_path != nil && (^u8)(panic_log_path)^ != 0 {
        fd := sce.sceIoOpen(panic_log_path, sce.O_WRONLY | sce.O_CREAT | sce.O_APPEND, 0o777)
        if fd >= 0 {
            sce.sceIoWrite(fd, raw_data(line[:]), sce.Size(n))
            sce.sceIoClose(fd)
        }
    }

    if panic_action == .Exit do sce.sceKernelExitProcess(1)
    runtime.trap()
}
