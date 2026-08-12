#!/usr/bin/env sh
# Puts SDL3.dll beside a program that needs it, taken from the Odin
# installation rather than from a copy kept in this repository.
#
# Why not just commit the dll: a checked-in copy goes stale silently. This
# repository shipped SDL 3.3.0 for months while vendor:sdl3's bindings were
# generated against 3.4.2, so every build was calling a two-minor-versions-old
# runtime through newer headers and nothing said so. Taking it from the Odin
# tree means the library and the bindings cannot disagree.
#
#   ./copy_sdl.sh              populate every example
#   ./copy_sdl.sh <directory>  put it in one place, e.g. your own game's build
#
# Windows only in effect. Odin ships SDL3 for Windows and nothing else, and on
# other platforms matchbox links `system:SDL3` -- so there is no file to place
# and the system package is what matters. See the Linux notes in the README.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        echo "Nothing to copy on this platform: SDL3 comes from the system."
        echo "Install SDL3 (3.4.2 or newer) through your package manager, or build it."
        exit 0
        ;;
esac

if ! command -v odin >/dev/null 2>&1; then
    echo "[ERROR] odin not found on PATH." >&2
    exit 1
fi

# 'odin root' reports a Windows path with a trailing backslash
ODIN_ROOT="$(odin root)"
if command -v cygpath >/dev/null 2>&1; then
    ODIN_ROOT="$(cygpath -u "$ODIN_ROOT")"
fi

SRC="${ODIN_ROOT%/}/vendor/sdl3/SDL3.dll"

if [ ! -f "$SRC" ]; then
    echo "[ERROR] SDL3.dll not found at $SRC" >&2
    exit 1
fi

if [ -n "$1" ]; then
    if [ ! -d "$1" ]; then
        echo "[ERROR] No such directory: $1" >&2
        exit 1
    fi
    cp -f "$SRC" "$1/"
    echo "Copied SDL3.dll to $1"
    exit 0
fi

echo "=== Copying SDL3.dll from the Odin vendor tree ==="

for dir in "$ROOT"/examples/*/; do
    [ -d "$dir" ] || continue
    cp -f "$SRC" "$dir"
    echo "-- $(basename "$dir")"
done

# TankMovement builds into a subdirectory, so the exe there needs its own copy
if [ -d "$ROOT/examples/TankMovement/build" ]; then
    cp -f "$SRC" "$ROOT/examples/TankMovement/build/"
    echo "-- TankMovement/build"
fi

echo "=== Done ==="
