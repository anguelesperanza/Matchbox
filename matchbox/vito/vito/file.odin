package vito

import "base:runtime"
import sce "../sce"

// Reads a whole file into memory from `allocator` (free it with `delete`).
// Use "app0:/assets/..." for files packed in the VPK.
//
// Link: -lSceLibKernel_stub -lSceIofilemgr_stub.
read_entire_file :: proc(path: cstring, allocator := context.allocator) -> (data: []u8, ok: bool) {
    stat: sce.IoStat
    if sce.sceIoGetstat(path, &stat) < 0 do return nil, false
    size := int(stat.st_size)
    if size < 0 do return nil, false

    fd := sce.sceIoOpen(path, sce.O_RDONLY, 0)
    if fd < 0 do return nil, false
    defer sce.sceIoClose(fd)

    err: runtime.Allocator_Error
    data, err = make([]u8, size, allocator)
    if err != nil do return nil, false

    done := 0
    for done < size {
        n := sce.sceIoRead(fd, raw_data(data[done:]), sce.Size(size - done))
        if n <= 0 {
            delete(data, allocator)
            return nil, false
        }
        done += int(n)
    }
    return data, true
}

// Writes `data` to a file, replacing it if it exists. Use a writable location
// such as "savedata0:/..." or "ux0:data/<title id>/...".
write_entire_file :: proc "contextless" (path: cstring, data: []u8) -> bool {
    fd := sce.sceIoOpen(path, sce.O_WRONLY | sce.O_CREAT | sce.O_TRUNC, 0o777)
    if fd < 0 do return false
    defer sce.sceIoClose(fd)
    done := 0
    for done < len(data) {
        n := sce.sceIoWrite(fd, raw_data(data[done:]), sce.Size(len(data) - done))
        if n <= 0 do return false
        done += int(n)
    }
    return true
}
