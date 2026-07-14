@echo off
setlocal enabledelayedexpansion

REM gpu_compiler.exe transpiles a NoSL shader straight to SPIR-V. The shader stage is
REM inferred from the .vert/.frag/.comp infix in the filename, and the output is named
REM <prefix>.<stage>.spv derived from the -out path (any extension on -out is stripped).
REM So for test.vert.nosl we pass -out:...\test.vert.spv and get ...\test.vert.spv directly.
REM NOTE: -out must include a directory component (an absolute path here), otherwise the
REM compiler silently writes nothing.

set COMPILER=%~dp0\compiler\gpu_compiler.exe

if not exist "%COMPILER%" (
    echo ERROR: gpu_compiler.exe not found at %COMPILER%
    exit /b 1
)

echo === Compiling NOSL shaders ===

for /r %%f in (*.nosl) do (
    echo -- Compiling %%f
    "%COMPILER%" "%%f" -out:"%%~dpnf.spv"
    if errorlevel 1 (
        echo ERROR: Failed to compile %%f
        exit /b 1
    )
)

echo === Done ===
