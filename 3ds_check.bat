@echo off
:: Checks the game in the folder given, or the one at the repository root when none is.
:: 3ds_check.bat examples\handheld-boot
set SRC=%~1
if "%SRC%"=="" set SRC=.
odin check %SRC% -target:freestanding_arm32 -no-entry-point -no-thread-local -max-error-count:100
