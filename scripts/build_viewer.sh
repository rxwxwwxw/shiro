#!/bin/sh
# Builds the SDL3 map viewer into bin/shiro_viewer. Usage: scripts/build_viewer.sh [--debug] [--asan]
# Run scripts/build_third_party.sh first.
set -e
cd "$(dirname "$0")/.."
prefix=build/third-party/install
if ! ls "$prefix"/lib/libSDL3.* >/dev/null 2>&1; then
    echo "error: SDL3 not built yet; run scripts/build_third_party.sh" >&2
    exit 1
fi
opt="-O2"
san=""
for a in "$@"; do
    case "$a" in
        --debug) opt="-g" ;;
        --asan) san="-fsanitize=address" ;;
    esac
done
case "$(uname -s)" in
    Darwin) origin="@executable_path" ;;
    *) origin='$ORIGIN' ;;
esac
mkdir -p build bin
cc -std=c11 $opt $san -c src/gui/nk_impl.c -I"$prefix/include" -Ithird-party/Nuklear \
    -Ithird-party/Nuklear/demo/sdl3_renderer -o build/nk_impl.o
# The bare -i skips druntime's `core` package, which our src/core modules share a name with.
cc -std=c11 $opt $san -c src/gfx/gpu_scene.c -I"$prefix/include" -o build/gpu_scene.o
ldc2 -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app -i=core.bitset -i=core.noise -i=core.random \
    -i=core.result -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w $opt $san src/app.d \
    build/nk_impl.o build/gpu_scene.o -L-L"$prefix/lib" -L-lSDL3 -L-rpath -L"$origin/../$prefix/lib" \
    -of=bin/shiro_viewer
echo "built bin/shiro_viewer"
