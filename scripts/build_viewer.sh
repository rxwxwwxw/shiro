#!/bin/sh
# Builds the SDL3 map viewer into bin/shiro_viewer. Usage: scripts/build_viewer.sh [--debug] [--asan] [--static]
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
static=0
for a in "$@"; do
    case "$a" in
        --debug) opt="-g" ;;
        --asan) san="-fsanitize=address" ;;
        --static) static=1 ;;
    esac
done
case "$(uname -s)" in
    Darwin) origin="@executable_path" ;;
    *) origin='$ORIGIN' ;;
esac
mkdir -p build/obj bin
cc -std=c11 $opt $san -c src/gui/nk_impl.c -I"$prefix/include" -Ithird-party/Nuklear \
    -Ithird-party/Nuklear/demo/sdl3_renderer -o build/obj/nk_impl.o
# The bare -i skips druntime's `core` package, which our src/core modules share a name with.
cc -std=c11 $opt $san -c src/gfx/gpu_scene.c -I"$prefix/include" -o build/obj/gpu_scene.o

if [ $static -eq 1 ]; then
    case "$(uname -s)" in
        Darwin)
            ldc2 -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app -i=core.bitset -i=core.noise -i=core.random \
                -i=core.result -i=core.json -i=core.file -i=story -i=village -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w $opt $san -od=build/obj src/app.d \
                build/obj/nk_impl.o build/obj/gpu_scene.o "$prefix/lib/libSDL3.a" \
                -L-framework -LCoreMedia -L-framework -LCoreVideo -L-framework -LCocoa -L-weak_framework -LUniformTypeIdentifiers \
                -L-framework -LIOKit -L-framework -LForceFeedback -L-framework -LCarbon -L-framework -LCoreAudio \
                -L-framework -LAudioToolbox -L-framework -LAVFoundation -L-framework -LFoundation -L-framework -LGameController \
                -L-framework -LMetal -L-framework -LQuartzCore -L-weak_framework -LCoreHaptics -L-lpthread -L-lm \
                -of=bin/shiro_viewer
            ;;
        *)
            ldc2 -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app -i=core.bitset -i=core.noise -i=core.random \
                -i=core.result -i=core.json -i=core.file -i=story -i=village -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w $opt $san -od=build/obj src/app.d \
                build/obj/nk_impl.o build/obj/gpu_scene.o "$prefix/lib/libSDL3.a" -L-lpthread -L-ldl -L-lm \
                -of=bin/shiro_viewer
            ;;
    esac
else
    ldc2 -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app -i=core.bitset -i=core.noise -i=core.random \
        -i=core.result -i=core.json -i=core.file -i=story -i=village -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w $opt $san -od=build/obj src/app.d \
        build/obj/nk_impl.o build/obj/gpu_scene.o -L-L"$prefix/lib" -L-lSDL3 -L-rpath -L"$origin" -L-rpath -L"$origin/../$prefix/lib" \
        -of=bin/shiro_viewer
    case "$(uname -s)" in
        Darwin)
            if [ -f "$prefix/lib/libSDL3.0.dylib" ]; then
                cp -f "$prefix/lib/libSDL3.0.dylib" bin/
                ln -sf libSDL3.0.dylib bin/libSDL3.dylib 2>/dev/null || true
            fi
            ;;
        *)
            if [ -f "$prefix/lib/libSDL3.so" ]; then
                cp -f "$prefix/lib/libSDL3.so"* bin/ 2>/dev/null || true
            fi
            ;;
    esac
fi
echo "built bin/shiro_viewer"
