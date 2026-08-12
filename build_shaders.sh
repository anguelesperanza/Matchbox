#!/usr/bin/env sh
# Compiles matchbox/shaders/*.hlsl to both SPIR-V (Vulkan) and DXIL (D3D12).
#
# SDL3_GPU only offers a backend whose shader format you declared at
# SDL_CreateGPUDevice, so both blobs are needed for the D3D12 fallback to exist
# at all. dxc from the Vulkan SDK emits both from the same source --
# SDL_shadercross is not required.
#
# DXIL is Windows-only in practice; on other platforms the dxil step is skipped
# and the SPIR-V output alone drives the Vulkan backend.
set -e

SHADER_DIR="$(cd "$(dirname "$0")" && pwd)/matchbox/shaders"

if ! command -v dxc >/dev/null 2>&1; then
    echo "[ERROR] dxc not found on PATH. Install the Vulkan SDK and add its Bin directory to PATH." >&2
    exit 1
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) WANT_DXIL=1 ;;
    *)                    WANT_DXIL=0 ;;
esac

echo "=== Compiling HLSL shaders ==="

for f in "$SHADER_DIR"/*.hlsl; do
    base="$(basename "$f" .hlsl)"
    case "$base" in
        *.vert) profile=vs_6_0 ;;
        *.frag) profile=ps_6_0 ;;
        *) echo "-- skipping $base (no .vert/.frag stage in name)"; continue ;;
    esac

    echo "-- $(basename "$f")"
    dxc -T "$profile" -E main -spirv -Fo "$SHADER_DIR/$base.spv" "$f"
    if [ "$WANT_DXIL" = "1" ]; then
        dxc -T "$profile" -E main -Fo "$SHADER_DIR/$base.dxil" "$f"
    fi
done

echo "=== Done ==="
