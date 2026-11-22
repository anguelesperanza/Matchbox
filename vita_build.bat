@echo off
setlocal enabledelayedexpansion
:: ---------------------------------------------------------------
:: Builds a .vpk for the PS Vita. Based on vito's NewProjectTemplate\build.bat
:: (the separate vito repository); the differences are marked "Matchbox:".
::
:: vita_build.bat examples\handheld-boot
:: ---------------------------------------------------------------
:: Project settings -- update these for your project
::
:: TITLE_ID must be exactly 9 characters: 4 letters + 5 digits.
:: ---------------------------------------------------------------
set TARGET=MyGame
set TITLE_ID=MBOX00001
set TITLE=My Game
:: Matchbox: the game to build: the folder given, or the one at the repository root when
:: none is. Assets and main.c stay at the root, as for 3ds_build.bat
set SRC=%~1
if "%SRC%"=="" set SRC=.
:: Matchbox: what gets built is matchbox\handheld_entry, which imports the game through this
:: collection, so the game needs no entry file and its package can have any name
for %%I in ("%SRC%") do set "GAME_DIR=%%~fI"
:: ---------------------------------------------------------------
:: VitaSDK - default install location of vdpm's bootstrap-vitasdk.ps1.
:: Override by setting VITASDK before running this script.
:: ---------------------------------------------------------------
if "%VITASDK%"=="" set VITASDK=C:\vitasdk
set PATH=%VITASDK%\bin;%PATH%
where arm-vita-eabi-gcc >nul 2>nul
if errorlevel 1 (
    echo arm-vita-eabi-gcc not found. Check VITASDK=%VITASDK%
    exit /b 1
)
:: ---------------------------------------------------------------
:: Folder layout
:: ---------------------------------------------------------------
set BUILD=build
set ODINASM=odin_asm
:: Matchbox: the bindings live in matchbox\vito, not ..\lib
set LIB=matchbox\vito
:: C files compiled with the project, one per lib\<name>\bridge.c. libm makes Odin's
:: maths work; sce is needed by gfx.
set BRIDGES=libm sce
set BRIDGE_OPT=-O2
set ARCH=-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard
:: ---------------------------------------------------------------
:: Clean previous build
:: ---------------------------------------------------------------
if exist %BUILD%   rd /s /q %BUILD%
if exist %ODINASM% rd /s /q %ODINASM%
mkdir %BUILD%
mkdir %ODINASM%
:: ---------------------------------------------------------------
:: Matchbox: stage the assets the way 3ds_build.bat does -- shared ones from assets\, the
:: Vita's own from assets\vita\, which win when both have a file -- so the .vpk carries
:: app0:/assets/images and app0:/assets/audio and nothing meant for another target
:: ---------------------------------------------------------------
set STAGE=%BUILD%\assets_stage
mkdir %STAGE%\images
mkdir %STAGE%\audio
call :stage_images assets\images
call :stage_images assets\vita\images
if exist assets\audio       xcopy /E /Y /I assets\audio       %STAGE%\audio  >nul
if exist assets\vita\audio  xcopy /E /Y /I assets\vita\audio  %STAGE%\audio  >nul
echo.
echo === Building %TARGET% ===
:: ---------------------------------------------------------------
:: Compile Odin -> ARM assembly
:: Matchbox: -define:MATCHBOX_VITA=true picks the Vita's files (matchbox\target.odin)
:: ---------------------------------------------------------------
echo.
echo Building Odin assembly...
odin build matchbox\handheld_entry -collection:matchbox_game="%GAME_DIR%" -target:freestanding_arm32 -o:speed -build-mode:asm -no-entry-point -min-link-libs -no-thread-local -microarch:cortex-a9 -define:MATCHBOX_VITA=true
if errorlevel 1 goto :fail
for %%f in (*.S) do (
    ren "%%f" "%%~nf.odin.s"
    move "%%~nf.odin.s" "%ODINASM%\" >nul
)
echo Compiling Odin assembly...
for %%f in (%ODINASM%\*.odin.s) do (
    echo  - %%f
    arm-vita-eabi-gcc -c "%%f" -o "%BUILD%\%%~nf.o" %ARCH%
    if errorlevel 1 goto :fail
    REM Odin emits soft-float objects; VitaSDK is hard-float and ld rejects the mix
    REM unless the ABI attributes are dropped. Floats cross into SCE libs via bridge.c.
    REM libm calls made by Odin (sinf, fmaxf, ...) are renamed to the vito_* wrappers
    REM in matchbox\vito\libm\bridge.c, which convert between the two float conventions.
    arm-vita-eabi-objcopy --remove-section .ARM.attributes --redefine-syms="%LIB%\libm\redefine.syms" "%BUILD%\%%~nf.o"
    if errorlevel 1 goto :fail
)
:: ---------------------------------------------------------------
:: Compile main.c entry shim
:: Matchbox: the root main.c, the same one 3ds_build.bat uses. It is plain C with nothing
:: console-specific in it, so one copy serves both
:: ---------------------------------------------------------------
echo.
echo Compiling main.c...
arm-vita-eabi-gcc -c main.c -o "%BUILD%\main.o" %ARCH%
if errorlevel 1 goto :fail
:: ---------------------------------------------------------------
:: Compile library ABI bridges, one per lib\<name>\bridge.c listed in BRIDGES
:: ---------------------------------------------------------------
echo.
echo Compiling lib bridges...
for %%b in (%BRIDGES%) do (
    echo  - %LIB%\%%b\bridge.c
    arm-vita-eabi-gcc -c "%LIB%\%%b\bridge.c" -o "%BUILD%\%%b_bridge.o" %ARCH% %BRIDGE_OPT%
    if errorlevel 1 goto :fail
)
:: ---------------------------------------------------------------
:: Link ELF (stub libs resolve SCE imports at load time)
:: ---------------------------------------------------------------
set OBJ=
for %%f in (%BUILD%\*.o) do set OBJ=!OBJ! %%f
echo.
echo Linking ELF...
:: -Wl,-q keeps relocations in the ELF. vita-elf-create turns them into .sce.rel so
:: the loader can relocate the module (real hardware randomizes the load address).
:: __sce_headroom leaves 64 KiB between the code and data segments. vita-elf-create
:: appends its SCE metadata to the code segment without checking that it fits; when
:: the code ended just below a 64 KiB boundary it overflowed and the tool crashed
:: (exit -1073740940, then "Cannot generate module NID" from vita-make-fself).
arm-vita-eabi-gcc -o "%BUILD%\%TARGET%.elf" %OBJ% %ARCH% -Wl,-q -Wl,--defsym,__sce_headroom=0x10000 ^
    -lSceDisplay_stub -lSceGxm_stub -lSceSysmodule_stub -lSceCtrl_stub -lSceTouch_stub -lSceMotion_stub -lSceKernelThreadMgr_stub -lSceIofilemgr_stub -lSceAudio_stub ^
    -lScePgf_stub -lScePvf_stub -lSceCommonDialog_stub -lSceAppMgr_stub -lSceAppUtil_stub -lScePower_stub -lSceSysmem_stub -lSceLibKernel_stub ^
    -lpng16 -lz -lm
if errorlevel 1 goto :fail
:: ---------------------------------------------------------------
:: Package: ELF -> velf -> eboot.bin, param.sfo -> .vpk
:: ---------------------------------------------------------------
echo.
echo Packaging VPK...
vita-elf-create "%BUILD%\%TARGET%.elf" "%BUILD%\%TARGET%.velf"
REM A crash gives a negative exit code, which "if errorlevel 1" does not catch.
if not "%errorlevel%"=="0" goto :fail
vita-make-fself -c "%BUILD%\%TARGET%.velf" "%BUILD%\eboot.bin"
if errorlevel 1 goto :fail
vita-mksfoex -s TITLE_ID=%TITLE_ID% "%TITLE%" "%BUILD%\param.sfo"
if errorlevel 1 goto :fail
:: Matchbox: the staged assets are packed as app0:/assets/..., and sce_sys\ (LiveArea icon
:: and pictures) as sce_sys/... when it exists
set VPK_ADD=-a %STAGE%=assets
if exist sce_sys set VPK_ADD=!VPK_ADD! -a sce_sys=sce_sys
vita-pack-vpk -s "%BUILD%\param.sfo" -b "%BUILD%\eboot.bin" !VPK_ADD! "%TARGET%.vpk"
if errorlevel 1 goto :fail
echo.
echo Build complete: %TARGET%.vpk
exit /b 0
:: ---------------------------------------------------------------
:: Copies one images folder into the stage, over what is there. A .meta describes the
:: picture beside it, so an image that replaces a staged one takes the staged .meta out
:: first: the Vita's own smaller copy read with the PC's .meta gets the wrong ppu and grid.
:: Its own .meta, when it has one, comes in with it. The same as in 3ds_build.bat
:: ---------------------------------------------------------------
:stage_images
if not exist "%~1" exit /b 0
set "FROM=%CD%\%~1\"
for /r "%~1" %%f in (*.png *.jpg *.jpeg) do (
    set "NAME=%%~dpnf"
    set "NAME=!NAME:%FROM%=!"
    if exist "%STAGE%\images\!NAME!.meta" del "%STAGE%\images\!NAME!.meta"
)
xcopy /E /Y /I "%~1" %STAGE%\images >nul
exit /b 0
:fail
echo.
echo Build FAILED
exit /b 1
