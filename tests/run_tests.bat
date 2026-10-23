@echo off
rem Builds and runs the unit + integration suites on Windows.
rem Usage: tests\run_tests.bat [--full] [--asan]
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
cd /d "%ROOT%"
set "OUT=build\test_runner.exe"
set "SAN="
set "ARGS="

:parse_args
if "%~1"=="" goto after_args
if "%~1"=="--asan" (
    set "SAN=-fsanitize=address"
)
if "%~1"=="--full" (
    set "ARGS=--full"
)
shift
goto parse_args
:after_args

if not exist "build\obj" mkdir "build\obj"

ldc2 -i=wfc -i=td -i=tests -i=viewer -i=gfx -i=core.bitset -i=core.noise -i=core.random -i=core.result -I. -Isrc ^
    -defaultlib=druntime-ldc -fno-exceptions -g -unittest %SAN% -od=build\obj tests\test_runner.d -of="%OUT%"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

"%OUT%" %ARGS%
exit /b %ERRORLEVEL%
