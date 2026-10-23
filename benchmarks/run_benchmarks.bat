@echo off
rem Builds and runs the microbenchmarks in release mode on Windows.
rem Usage: benchmarks\run_benchmarks.bat [scale-cells...]
setlocal enabledelayedexpansion

set "ROOT=%~dp0.."
cd /d "%ROOT%"
set "OUT=build\bench"

if not exist "%OUT%\obj" mkdir "%OUT%\obj"

set "FLAGS=-O3 -release -boundscheck=off -defaultlib=druntime-ldc -fno-exceptions -i=wfc -i=td -i=core.bitset -i=core.noise -i=core.random -i=core.result -I. -Isrc -od=%OUT%\obj"

for %%b in (bench_propagation bench_wfc_solve bench_scale bench_routes bench_td_tick) do (
    echo ==> Building %%b.exe...
    ldc2 %FLAGS% benchmarks\%%b.d -of="%OUT%\%%b.exe"
    if !ERRORLEVEL! neq 0 exit /b !ERRORLEVEL!
)

"%OUT%\bench_propagation.exe"
"%OUT%\bench_wfc_solve.exe"
"%OUT%\bench_routes.exe"
"%OUT%\bench_td_tick.exe"
"%OUT%\bench_scale.exe" 8 %*
exit /b 0
