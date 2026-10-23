#!/bin/sh
# Builds and runs the microbenchmarks in release mode. Usage: benchmarks/run_benchmarks.sh [scale-cells...]
set -e
cd "$(dirname "$0")/.."
out=${TMPDIR:-/tmp}/shiro_bench
mkdir -p "$out"
flags="-O3 -release -boundscheck=off -defaultlib=druntime-ldc -fno-exceptions -i=wfc -i=td -i=core.bitset -i=core.noise -i=core.random -i=core.result -i=core.json -i=core.file -i=story -i=village -i=npegged -I. -Isrc -od=$out"
for b in bench_propagation bench_wfc_solve bench_scale bench_routes bench_td_tick bench_village_gen bench_story; do
    ldc2 $flags benchmarks/$b.d -of="$out/$b"
done
"$out/bench_propagation"
"$out/bench_wfc_solve"
"$out/bench_routes"
"$out/bench_td_tick"
"$out/bench_village_gen"
"$out/bench_story"
"$out/bench_scale" 8 "$@"
