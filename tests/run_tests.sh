#!/bin/sh
# Builds and runs the unit + integration suites. Usage: tests/run_tests.sh [--full] [--asan]
set -e
cd "$(dirname "$0")/.."
out=${TMPDIR:-/tmp}/shiro_test_runner
san=""
args=""
for a in "$@"; do
    case "$a" in
        --asan) san="-fsanitize=address" ;;
        --full) args="--full" ;;
    esac
done
# The bare -i skips druntime's `core` package, which our src/core modules share a name with.
ldc2 -i=wfc -i=td -i=tests -i=viewer -i=gfx -i=core.bitset -i=core.noise -i=core.random -i=core.result -i=core.json -i=core.file -i=story -i=village -I. -Isrc \
    -defaultlib=druntime-ldc -fno-exceptions -g -unittest $san -od="$(dirname "$out")" tests/test_runner.d -of="$out"
"$out" $args
