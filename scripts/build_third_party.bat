@echo off
rem Builds the vendored C dependencies into build/third-party/install on Windows.
rem Usage: scripts\build_third_party.bat [--force]
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
cd /d "%ROOT%"
set "PREFIX=%ROOT%\build\third-party\install"
set "FORCE=0"

if "%~1"=="--force" set "FORCE=1"

where cmake >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo error: cmake not found. Please install CMake and add it to PATH. >&2
    exit /b 1
)

if "%FORCE%"=="0" (
    if exist "%PREFIX%\lib\SDL3.lib" if exist "%PREFIX%\lib\SDL3-static.lib" (
        echo SDL3 already built (pass --force to rebuild)
        exit /b 0
    )
    if exist "%PREFIX%\lib\libSDL3.dll.a" if exist "%PREFIX%\lib\libSDL3.a" (
        echo SDL3 already built (pass --force to rebuild)
        exit /b 0
    )
)

set "JOBS=%NUMBER_OF_PROCESSORS%"
if "%JOBS%"=="" set "JOBS=4"

echo ==> Building SDL3 with CMake...
cmake -S "third-party\SDL3" -B "build\third-party\SDL3" -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_INSTALL_PREFIX="%PREFIX%" -DCMAKE_PREFIX_PATH="%PREFIX%" ^
    -DCMAKE_INSTALL_LIBDIR=lib -DSDL_SHARED=ON -DSDL_STATIC=ON ^
    -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

cmake --build "build\third-party\SDL3" --config Release --parallel %JOBS%
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

cmake --install "build\third-party\SDL3" --config Release
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

echo SDL3 successfully installed in %PREFIX%
exit /b 0
