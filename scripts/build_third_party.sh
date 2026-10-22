#!/bin/sh
# Builds the vendored C dependencies into build/third-party/install. Usage: scripts/build_third_party.sh [--force]
# Only SDL3 is needed today; the companion libraries are stubbed below until something uses them.
set -e
cd "$(dirname "$0")/.."
root=$(pwd)
prefix="$root/build/third-party/install"
force=0
for a in "$@"; do
    case "$a" in
        --force) force=1 ;;
    esac
done

if ! command -v cmake >/dev/null 2>&1; then
    echo "error: cmake not found. Install it first:" >&2
    echo "  macOS:  brew install cmake" >&2
    echo "  Debian: sudo apt install cmake" >&2
    exit 1
fi

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

# build_lib <name> [extra cmake args...]
build_lib() {
    name=$1
    shift
    cmake -S "third-party/$name" -B "build/third-party/$name" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix" "$@"
    cmake --build "build/third-party/$name" --config Release --parallel "$jobs"
    cmake --install "build/third-party/$name" --config Release
}

if [ $force -eq 1 ] || ! ls "$prefix"/lib/libSDL3.* >/dev/null 2>&1; then
    build_lib SDL3 -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF
else
    echo "SDL3 already built (pass --force to rebuild)"
fi

# Not needed by the viewer yet:
# build_lib SDL3_image -DSDL3_DIR="$prefix/lib/cmake/SDL3" -DSDLIMAGE_VENDORED=OFF
# build_lib SDL3_ttf   -DSDL3_DIR="$prefix/lib/cmake/SDL3"
# build_lib SDL3_mixer -DSDL3_DIR="$prefix/lib/cmake/SDL3"
# build_lib SDL3_net   -DSDL3_DIR="$prefix/lib/cmake/SDL3"
