#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPILER="$SCRIPT_DIR/compiler/gpu_compiler"
SHADERS_DIR="$SCRIPT_DIR/matchbox/shaders"

if [ ! -f "$COMPILER" ]; then
    echo "ERROR: gpu_compiler not found at $COMPILER"
    exit 1
fi

if [ ! -d "$SHADERS_DIR" ]; then
    echo "ERROR: shaders directory not found at $SHADERS_DIR"
    exit 1
fi

echo "=== Compiling NOSL shaders ==="

while IFS= read -r -d '' f; do
    echo "-- Compiling $f"
    dir=$(dirname "$f")
    base=$(basename "$f" .nosl)
    out="$dir/$base"

    if ! "$COMPILER" "$f" "$out"; then
        echo "ERROR: Failed to compile $f"
        exit 1
    fi
done < <(find "$SHADERS_DIR" -name "*.nosl" -print0)

echo "=== Done ==="
