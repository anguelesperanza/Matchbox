@echo off
setlocal enabledelayedexpansion

REM Builds an Odin package that uses matchbox into an installable .apk.
REM
REM This script lives inside the matchbox folder on purpose. Drop matchbox into
REM a project and Android support comes with it, so the default target is the
REM directory matchbox sits in:
REM
REM   some_game\matchbox\android_apk.bat            builds some_game
REM   some_game\matchbox\android_apk.bat install    and installs it
REM
REM Give it a path to build something else -- which is how this repository builds
REM its own examples, since they sit beside matchbox rather than above it:
REM
REM   matchbox\android_apk.bat examples\ui
REM   matchbox\android_apk.bat examples\ui install
REM   matchbox\android_apk.bat C:\path\to\game install
REM
REM Prerequisites, once per machine:
REM
REM   matchbox\android.bat       cross-compiles stb for arm64
REM   matchbox\android_sdl.bat   fetches libSDL3.so and SDL's Java classes
REM   ODIN_ANDROID_NDK           and ODIN_ANDROID_SDK set in the environment
REM   the vendor:stb patch described in improvements.md
REM
REM The one thing here that is not obvious:
REM
REM   -L matchbox\android\libs
REM
REM   vendor:stb names its archives by path, and Odin turns a path-named foreign
REM   import into -l:<absolute path>, which lld cannot use. The vendor bindings
REM   have to be patched to fall through to their "system:" form, and then this
REM   -L resolves them against the lib-prefixed archives android.bat writes.
REM
REM The entry point used to be a linker flag here, aliasing SDL_main onto Odin's
REM main. That was wrong -- in -build-mode:shared Odin's main is a stub that
REM returns 0 -- and it now lives in matchbox\android.odin, which explains itself
REM at length.

REM The one API level everything is built against. Odin defaults to 34, which
REM quietly produces a binary referencing symbols such as __register_atfork that
REM API 21's libc does not have -- while the manifest still advertised 21, so the
REM apk claimed devices it could not load on. It is one number here, spent on the
REM compile, the dex, the signature and the manifest, so the four cannot drift.
REM SDL's own .so and android.bat's stb are both built for 21 too.
set "APILEVEL=21"

REM MB is the matchbox folder this script is in, without the trailing slash.
set "MB=%~dp0"
set "MB=%MB:~0,-1%"

REM First argument is the package to build, unless it is the install verb.
set "TARGET=%~1"
set "DOINSTALL="
if /i "%TARGET%"=="install" (
    set "DOINSTALL=1"
    set "TARGET="
)
if /i "%~2"=="install" set "DOINSTALL=1"

REM No path given means "the project matchbox was dropped into", which is the
REM directory above this one.
if "%TARGET%"=="" (
    for %%i in ("%MB%\..") do set "GAME=%%~fi"
) else (
    for %%i in ("%TARGET%") do set "GAME=%%~fi"
)

if not exist "%GAME%" (
    echo [ERROR] No such directory: %GAME%
    exit /b 1
)

REM A package is a directory of .odin files. Fall back to src\ for projects that
REM keep their source a level down, which is what examples\TankMovement does.
set "SRC=%GAME%"
if not exist "%GAME%\*.odin" (
    if exist "%GAME%\src\*.odin" (
        set "SRC=%GAME%\src"
    ) else (
        echo [ERROR] No .odin files in %GAME% or %GAME%\src
        exit /b 1
    )
)

for %%i in ("%GAME%") do set "GAMENAME=%%~nxi"

set "LIBS=%MB%\android\libs"
set "OUT=%GAME%\build\android"

if not exist "%LIBS%\libSDL3.so" (
    echo [ERROR] No android\libs\libSDL3.so. Run matchbox\android_sdl.bat first.
    exit /b 1
)

if not exist "%LIBS%\SDL3-classes.jar" (
    echo [ERROR] No android\libs\SDL3-classes.jar. Run matchbox\android_sdl.bat first.
    exit /b 1
)

if not exist "%LIBS%\libstb_truetype.a" (
    echo [ERROR] No stb archives in android\libs. Run matchbox\android.bat first.
    exit /b 1
)

if not defined ODIN_ANDROID_SDK (
    echo [ERROR] ODIN_ANDROID_SDK is not set.
    exit /b 1
)

REM Pick the newest build-tools and platform the SDK has, rather than pinning a
REM version that only exists on the machine this was written on.
for /f "delims=" %%d in ('dir /b /ad /on "%ODIN_ANDROID_SDK%\build-tools" 2^>nul') do set "BTV=%%d"
for /f "delims=" %%d in ('dir /b /ad /on "%ODIN_ANDROID_SDK%\platforms" 2^>nul') do set "PLATV=%%d"

if not defined BTV (
    echo [ERROR] No build-tools under "%ODIN_ANDROID_SDK%\build-tools"
    exit /b 1
)
if not defined PLATV (
    echo [ERROR] No platforms under "%ODIN_ANDROID_SDK%\platforms"
    exit /b 1
)

set "BT=%ODIN_ANDROID_SDK%\build-tools\%BTV%"
set "ANDROID_JAR=%ODIN_ANDROID_SDK%\platforms\%PLATV%\android.jar"

REM A package name has to be a Java identifier, so the dashes have to go. Set
REM MATCHBOX_ANDROID_PACKAGE yourself for anything that will be published --
REM this default is fine for a debug build and wrong for a store.
set "PKGSUFFIX=%GAMENAME:-=%"
if defined MATCHBOX_ANDROID_PACKAGE (
    set "PACKAGE=%MATCHBOX_ANDROID_PACKAGE%"
) else (
    set "PACKAGE=org.matchbox.%PKGSUFFIX%"
)

echo === Building %GAMENAME% for Android arm64 ===
echo     from %SRC%
echo     build-tools %BTV%, %PLATV%, API %APILEVEL%

if exist "%OUT%" rmdir /s /q "%OUT%"
mkdir "%OUT%\lib\arm64-v8a"

echo -- compiling libmain.so
odin build "%SRC%" -target:linux_arm64 -subtarget:android -build-mode:shared ^
    -minimum-os-version:%APILEVEL% ^
    -out:"%OUT%\lib\arm64-v8a\libmain.so" ^
    -extra-linker-flags:"-L%LIBS%" || exit /b 1

copy /y "%LIBS%\libSDL3.so" "%OUT%\lib\arm64-v8a\" >nul || exit /b 1

echo -- dexing SDL's Java classes
call "%BT%\d8.bat" --min-api %APILEVEL% --lib "%ANDROID_JAR%" --output "%OUT%" "%LIBS%\SDL3-classes.jar" || exit /b 1

REM Everything the game ships that is not source becomes an asset, keeping its
REM path: art\coin.png is read back as "art/coin.png". That is the same string
REM the desktop build opens, because read_entire_file goes through SDL's
REM IOStream, which sends a relative path to the asset manager on Android and to
REM the filesystem everywhere else.
REM
REM matchbox itself is excluded. Its fonts and shaders are #load-ed into the
REM binary, so shipping them again as assets would be dead weight.
echo -- staging assets
robocopy "%SRC%" "%OUT%\assets" /E /XF *.odin *.dll *.so *.exe *.pdb *.lib /XD "%MB%" "%GAME%\build" "%GAME%\.git" >nul
if errorlevel 8 (
    echo [ERROR] Could not stage assets from %SRC%
    exit /b 1
)

set "ASSETFLAG="
dir /b /s /a-d "%OUT%\assets" 2>nul | findstr /r "." >nul && set "ASSETFLAG=-A assets"

echo -- manifest for %PACKAGE%
powershell -NoProfile -Command ^
    "(Get-Content '%MB%\android\AndroidManifest.xml' -Raw) -replace '__PACKAGE__','%PACKAGE%' -replace '__LABEL__','%GAMENAME%' -replace '__MINSDK__','%APILEVEL%' | Set-Content -NoNewline '%OUT%\AndroidManifest.xml'" || exit /b 1

echo -- packaging
pushd "%OUT%"
"%BT%\aapt.exe" package -f -M AndroidManifest.xml -I "%ANDROID_JAR%" %ASSETFLAG% -F app.apk-build || (popd & exit /b 1)

REM Forward slashes, deliberately. aapt writes the entry name exactly as given,
REM and Android only recognises a native library at lib/<abi>/, so a backslash
REM here produces an apk that installs and then dies in System.loadLibrary.
"%BT%\aapt.exe" add app.apk-build classes.dex lib/arm64-v8a/libmain.so lib/arm64-v8a/libSDL3.so >nul || (popd & exit /b 1)
popd

echo -- aligning
"%BT%\zipalign.exe" -p -f 4 "%OUT%\app.apk-build" "%OUT%\%GAMENAME%.apk" || exit /b 1

REM A self-signed debug key, kept beside the manifest so it travels with this
REM matchbox copy and every game built from it is signed by the same one.
REM Android refuses to install an unsigned apk, so this is not optional even for
REM a throwaway build. It is not a release key and the password is not a secret;
REM 'android' is the convention the SDK's own debug keystore uses. Gitignored.
REM
REM Losing it is survivable: Android will not replace an apk signed by a
REM different key, so the next install has to be an uninstall first.
if not exist "%MB%\android\debug.keystore" (
    echo -- generating android\debug.keystore
    keytool -genkeypair -keystore "%MB%\android\debug.keystore" ^
        -storepass android -keypass android -alias androiddebugkey ^
        -keyalg RSA -keysize 2048 -validity 10000 ^
        -dname "CN=Matchbox Debug,O=Matchbox,C=US" || exit /b 1
)

echo -- signing
call "%BT%\apksigner.bat" sign --ks "%MB%\android\debug.keystore" ^
    --ks-pass pass:android --key-pass pass:android ^
    --ks-key-alias androiddebugkey --min-sdk-version %APILEVEL% ^
    "%OUT%\%GAMENAME%.apk" || exit /b 1

del "%OUT%\app.apk-build" >nul 2>nul

echo === Built %OUT%\%GAMENAME%.apk ===

if not defined DOINSTALL (
    echo.
    echo     pass "install" to push it to a connected phone and launch it
)
if defined DOINSTALL (
    echo -- installing
    "%ODIN_ANDROID_SDK%\platform-tools\adb.exe" install -r "%OUT%\%GAMENAME%.apk" || exit /b 1
    echo -- launching
    "%ODIN_ANDROID_SDK%\platform-tools\adb.exe" shell am start -n %PACKAGE%/org.libsdl.app.SDLActivity >nul
    echo.
    echo     adb logcat -s SDL:V DEBUG:V     to see what it says
    echo     if that is silent, check: adb shell getprop log.tag
)

endlocal
