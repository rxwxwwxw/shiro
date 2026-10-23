@echo off
rem Builds the SDL3 map viewer into bin\shiro_viewer.exe on Windows.
rem Usage: scripts\build_viewer.bat [--debug] [--asan] [--static]
rem Run scripts\build_third_party.bat first.
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
cd /d "%ROOT%"
set "PREFIX=%ROOT%\build\third-party\install"

if not exist "%PREFIX%\include\SDL3\SDL.h" (
    echo error: SDL3 not built yet; run scripts\build_third_party.bat >&2
    exit /b 1
)

set "OPT=-O2 -release -boundscheck=safeonly"
set "COPT=-O2"
set "SAN="
set "STATIC=1"

:parse_args
if "%~1"=="" goto after_args
if "%~1"=="--debug" (
    set "OPT=-g -d-debug"
    set "COPT=-g -O0"
)
if "%~1"=="--asan" (
    set "SAN=-fsanitize=address"
)
if "%~1"=="--dynamic" (
    set "STATIC=0"
)
if "%~1"=="--static" (
    set "STATIC=1"
)
shift
goto parse_args
:after_args

if not exist "build\obj" mkdir "build\obj"
if not exist "bin" mkdir "bin"

rem Determine C compiler: prefer clang, then cc, then gcc
set "CC="
where clang >nul 2>nul && set "CC=clang"
if "%CC%"=="" (
    where cc >nul 2>nul && set "CC=cc"
)
if "%CC%"=="" (
    where gcc >nul 2>nul && set "CC=gcc"
)
if "%CC%"=="" (
    echo error: No C compiler (clang/cc/gcc) found in PATH. >&2
    exit /b 1
)

echo ==> Compiling C objects with %CC%...
%CC% -std=c11 %COPT% %SAN% -c src\gui\nk_impl.c -I"%PREFIX%\include" -Ithird-party\Nuklear -Ithird-party\Nuklear\demo\sdl3_renderer -o build\obj\nk_impl.obj
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

%CC% -std=c11 %COPT% %SAN% -c src\gfx\gpu_scene.c -I"%PREFIX%\include" -o build\obj\gpu_scene.obj
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo ==> Building bin\shiro_viewer.exe with ldc2 (static=%STATIC%)...
if "%STATIC%"=="1" (
    if exist "%PREFIX%\lib\SDL3-static.lib" (
        set "LINK_STATIC=%PREFIX%\lib\SDL3-static.lib -Luser32.lib -Lgdi32.lib -Lwinmm.lib -Limm32.lib -Lole32.lib -Loleaut32.lib -Lversion.lib -Luuid.lib -Ladvapi32.lib -Lsetupapi.lib -Lshell32.lib -Lcfgmgr32.lib"
    ) else (
        set "LINK_STATIC=%PREFIX%\lib\libSDL3.a -L-luser32 -L-lgdi32 -L-lwinmm -L-limm32 -L-lole32 -L-loleaut32 -L-lversion -L-luuid -L-ladvapi32 -L-lsetupapi -L-lshell32 -L-lcfgmgr32"
    )
    ldc2 -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app -i=core.bitset -i=core.noise -i=core.random ^
        -i=core.result -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w %OPT% %SAN% -od=build\obj src\app.d ^
        build\obj\nk_impl.obj build\obj\gpu_scene.obj !LINK_STATIC! -of=bin\shiro_viewer.exe
) else (
    ldc2 -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app -i=core.bitset -i=core.noise -i=core.random ^
        -i=core.result -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w %OPT% %SAN% -od=build\obj src\app.d ^
        build\obj\nk_impl.obj build\obj\gpu_scene.obj -L-L"%PREFIX%\lib" -L-lSDL3 -of=bin\shiro_viewer.exe
    if exist "%PREFIX%\bin\SDL3.dll" (
        copy /y "%PREFIX%\bin\SDL3.dll" bin\ >nul
    )
)
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo built bin\shiro_viewer.exe
exit /b 0
