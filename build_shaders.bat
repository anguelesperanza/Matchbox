@echo off
setlocal enabledelayedexpansion

REM The updated gpu_compiler.exe transpiles a combined NoSL file (#vertex/#fragment)
REM straight to SPIR-V, emitting output.<entry>.spv in the current directory. No
REM glslangValidator step is needed anymore. It always names outputs "output.*", so we
REM compile each shader in its own directory and rename to <name>.<stage>.spv.

set COMPILER=%~dp0\compiler\gpu_compiler.exe

if not exist "%COMPILER%" (
    echo ERROR: gpu_compiler.exe not found at %COMPILER%
    exit /b 1
)

echo === Compiling NOSL shaders ===

for /r %%f in (*.nosl) do (
    echo -- Compiling %%f
    pushd "%%~dpf"
    "%COMPILER%" "%%~nxf"
    if errorlevel 1 (
        echo ERROR: Failed to compile %%f
        popd
        exit /b 1
    )
    if exist output.vert.spv move /y output.vert.spv "%%~nf.vert.spv" >nul
    if exist output.frag.spv move /y output.frag.spv "%%~nf.frag.spv" >nul
    if exist output.comp.spv move /y output.comp.spv "%%~nf.comp.spv" >nul
    popd
)

echo === Done ===
