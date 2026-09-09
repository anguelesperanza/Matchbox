@echo off
setlocal enabledelayedexpansion

REM Compiles matchbox/shaders/*.hlsl to both SPIR-V (Vulkan) and DXIL (D3D12).
REM
REM SDL3_GPU only offers a backend whose shader format you declared at
REM SDL_CreateGPUDevice, so both blobs are needed for the D3D12 fallback to
REM exist at all. dxc from the Vulkan SDK emits both from the same source --
REM SDL_shadercross is not required.
REM
REM Stage comes from the .vert. / .frag. infix in the filename, same as the
REM NoSL script this replaces.

set SHADER_DIR=%~dp0matchbox\shaders

where dxc >nul 2>nul
if errorlevel 1 (
    echo [ERROR] dxc not found on PATH. Install the Vulkan SDK, or add its Bin
    echo         directory ^(e.g. C:\VulkanSDK\^<version^>\Bin^) to PATH.
    exit /b 1
)

echo === Compiling HLSL shaders ===

REM -I points -include lookups at shaders/ itself, so a module can
REM #include "brdf/blinn_phong.hlsli" (say) by a stable path from any file
REM rather than a relative one -- dxc resolves a bare #include relative to
REM the including file regardless, so this only matters for an include
REM written relative to shaders/ rather than to its own directory.
for %%F in ("%SHADER_DIR%\*.vert.hlsl") do (
    echo -- %%~nxF
    dxc -T vs_6_0 -E main -I "%SHADER_DIR%" -spirv -Fo "%SHADER_DIR%\%%~nF.spv"  "%%F" || exit /b 1
    dxc -T vs_6_0 -E main -I "%SHADER_DIR%"         -Fo "%SHADER_DIR%\%%~nF.dxil" "%%F" || exit /b 1
)

for %%F in ("%SHADER_DIR%\*.frag.hlsl") do (
    echo -- %%~nxF
    dxc -T ps_6_0 -E main -I "%SHADER_DIR%" -spirv -Fo "%SHADER_DIR%\%%~nF.spv"  "%%F" || exit /b 1
    dxc -T ps_6_0 -E main -I "%SHADER_DIR%"         -Fo "%SHADER_DIR%\%%~nF.dxil" "%%F" || exit /b 1
)

echo === Done ===
endlocal
