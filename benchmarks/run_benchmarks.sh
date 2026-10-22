#!/bin/sh
# Builds and runs the microbenchmarks in release mode. Usage: benchmarks/run_benchmarks.sh [scale-cells...]
set -e
cd "$(dirname "$0")/.."
out=${TMPDIR:-/tmp}/shiro_bench
mkdir -p "$out"
flags="-O3 -release -boundscheck=off -defaultlib=druntime-ldc -fno-exceptions -i=wfc -i=td -i=core.bitset -i=core.noise -i=core.random -i=core.result -I. -Isrc"
for b in bench_propagation bench_wfc_solve bench_scale bench_routes bench_td_tick; do
    ldc2 $flags benchmarks/$b.d -of="$out/$b"
done
"$out/bench_propagation"
"$out/bench_wfc_solve"
"$out/bench_routes"
"$out/bench_td_tick"
"$out/bench_scale" 8 "$@"
