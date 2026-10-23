# Shiro Tower Defense Engine Makefile
# Supports: macOS (Apple Silicon / Intel), Linux (x86_64 / AArch64), Windows 10 (MSVC / MinGW)

# -----------------------------------------------------------------------------
# Platform & Architecture Detection
# -----------------------------------------------------------------------------

ifeq ($(OS),Windows_NT)
    PLATFORM := windows
    EXE := .exe
    OBJ := .obj
    STATIC_LIB := .lib
    ARCH ?= x86_64
    ifneq ($(findstring sh,$(SHELL)),)
        MKDIR := mkdir -p
        RM := rm -rf
        CP := cp -f
        SEP := /
        RUN_DIR := ./
    else
        MKDIR := cmake -E make_directory
        RM := cmake -E rm -rf
        CP := cmake -E copy_if_different
        SEP := \\
        RUN_DIR := 
    endif
    JOBS ?= $(if $(NUMBER_OF_PROCESSORS),$(NUMBER_OF_PROCESSORS),4)
else
    UNAME_S := $(shell uname -s)
    ARCH ?= $(shell uname -m)
    EXE :=
    OBJ := .o
    STATIC_LIB := .a
    MKDIR := mkdir -p
    RM := rm -rf
    CP := cp -f
    SEP := /
    RUN_DIR := ./
    JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    ifeq ($(UNAME_S),Darwin)
        PLATFORM := macos
    else ifeq ($(UNAME_S),Linux)
        PLATFORM := linux
    else
        PLATFORM := unix
    endif
endif

# Toolchain executables
CC ?= cc
LDC ?= ldc2
CMAKE ?= cmake
DFMT ?= dfmt

# -----------------------------------------------------------------------------
# Build Configuration & Directories (Partitioned by Build Type)
# -----------------------------------------------------------------------------

# Build configuration: release (default), debug, or profile
ifeq ($(DEBUG),1)
    BUILD := debug
else ifeq ($(PROFILE),1)
    BUILD := profile
else
    BUILD ?= release
endif

# Directory tree:
# build/
# ├── third-party/        # Vendored C dependencies (SDL3 build + install)
# └── $(BUILD)/           # release, debug, profile
#     ├── obj/            # Intermediate object files (.o / .obj)
#     ├── bin/            # Configuration-specific binaries
#     └── bench/          # Benchmark binaries
BUILD_DIR := build
CONFIG_DIR := $(BUILD_DIR)/$(BUILD)
OBJ_DIR := $(CONFIG_DIR)/obj
CONFIG_BIN_DIR := $(CONFIG_DIR)/bin
CONFIG_BENCH_DIR := $(CONFIG_DIR)/bench

BIN_DIR := bin
DIST_DIR := dist
PREFIX := $(CURDIR)/build/third-party/install

# Intermediate C objects placed in $(OBJ_DIR)
C_OBJS := $(OBJ_DIR)/nk_impl$(OBJ) $(OBJ_DIR)/gpu_scene$(OBJ)

# Output binaries
CONFIG_VIEWER_BIN := $(CONFIG_BIN_DIR)/shiro_viewer$(EXE)
VIEWER_BIN := $(BIN_DIR)/shiro_viewer$(EXE)
TEST_BIN := $(CONFIG_BIN_DIR)/test_runner$(EXE)

BENCH_NAMES := bench_propagation bench_wfc_solve bench_routes bench_td_tick bench_village_gen bench_scale
BENCH_BINS := $(addprefix $(CONFIG_BENCH_DIR)/,$(addsuffix $(EXE),$(BENCH_NAMES)))

# -----------------------------------------------------------------------------
# CPU Architecture & Optimization (Braswell Baseline)
# -----------------------------------------------------------------------------
# For x86_64 (Linux / Windows), the Braswell (Intel Airmont) baseline guarantees:
# - Hardware POPCNT, SSE4.2, SSSE3, SSE4.1, MOVBE
# - Strictly NO AVX/AVX2/FMA (which cause SIGILL on Braswell/Atom CPUs)
# - In LLVM/LDC, this corresponds to -mcpu=silvermont
ifeq ($(TARGET_CPU),)
    ifeq ($(ARCH),x86_64)
        TARGET_CPU := silvermont
    else ifeq ($(ARCH),amd64)
        TARGET_CPU := silvermont
    endif
endif

ifneq ($(TARGET_CPU),)
    D_CPU_FLAGS := -mcpu=$(TARGET_CPU)
    ifeq ($(findstring cl,$(notdir $(CC))),)
        C_CPU_FLAGS := -march=$(TARGET_CPU)
    else
        C_CPU_FLAGS :=
    endif
else
    D_CPU_FLAGS :=
    C_CPU_FLAGS :=
endif

# -----------------------------------------------------------------------------
# Compilation & Optimization Flags
# -----------------------------------------------------------------------------

ifeq ($(BUILD),debug)
    D_OPT_FLAGS := -g -d-debug
    C_OPT_FLAGS := -g -O0
else ifeq ($(BUILD),profile)
    D_OPT_FLAGS := -O2 -g -boundscheck=safeonly
    C_OPT_FLAGS := -O2 -g -fno-omit-frame-pointer
else
    # release
    D_OPT_FLAGS := -O2 -release -boundscheck=safeonly
    C_OPT_FLAGS := -O2
endif

ifeq ($(ASAN),1)
    D_SAN_FLAGS := -fsanitize=address
    C_SAN_FLAGS := -fsanitize=address
else
    D_SAN_FLAGS :=
    C_SAN_FLAGS :=
endif

# C Compiler Flags (supports GCC/Clang and MSVC cl.exe)
ifeq ($(findstring cl,$(notdir $(CC))),cl)
    C_FLAGS := /std:c11 $(C_OPT_FLAGS) $(C_SAN_FLAGS) /I"$(PREFIX)/include"
    C_OUT := /Fo
else
    C_FLAGS := -std=c11 $(C_OPT_FLAGS) $(C_CPU_FLAGS) $(C_SAN_FLAGS) -I"$(PREFIX)/include"
    C_OUT := -o 
endif

# D Compiler Flags (LDC2)
D_MODULES := -i=wfc -i=td -i=gfx -i=gui -i=viewer -i=bindings -i=app \
             -i=core.bitset -i=core.noise -i=core.random -i=core.result -i=core.json -i=core.file -i=story -i=village

D_TEST_MODULES := -i=wfc -i=td -i=tests -i=viewer -i=gfx \
                  -i=core.bitset -i=core.noise -i=core.random -i=core.result -i=core.json -i=core.file -i=story -i=village

D_BENCH_MODULES := -i=wfc -i=td -i=village \
                   -i=core.bitset -i=core.noise -i=core.random -i=core.result -i=core.json -i=core.file -i=story -i=village

D_COMMON_FLAGS := -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -w

# Source tracking for incremental builds
D_SRCS := $(shell find src -name "*.d" 2>/dev/null)
ifeq ($(D_SRCS),)
    D_SRCS := src/app.d $(wildcard src/*/*.d src/*/*/*.d src/*/*/*/*.d)
endif

TEST_SRCS := $(shell find tests -name "*.d" 2>/dev/null)
ifeq ($(TEST_SRCS),)
    TEST_SRCS := $(wildcard tests/*.d)
endif

# -----------------------------------------------------------------------------
# Linking Configuration (Static vs Dynamic)
# -----------------------------------------------------------------------------
# STATIC=1 (default) produces a standalone binary with SDL3 statically linked.
# Permissive licensing (SDL3 is zlib, druntime is Boost, Nuklear is MIT/PD) allows
# full static linking with zero copyleft obligations.
# STATIC=0 produces a dynamically linked binary and places the shared library
# alongside the executable in bin/ with RPATH set to $ORIGIN / @executable_path.
STATIC ?= 1

SDL3_HEADER := $(PREFIX)/include/SDL3/SDL.h
SDL3_STATIC_LIB := $(PREFIX)/lib/libSDL3.a

ifeq ($(PLATFORM),windows)
    SDL3_SHARED_LIB := $(if $(wildcard $(PREFIX)/lib/libSDL3.dll.a),$(PREFIX)/lib/libSDL3.dll.a,$(PREFIX)/lib/SDL3.lib)
    SDL3_DLL := $(PREFIX)/bin/SDL3.dll
else ifeq ($(PLATFORM),macos)
    SDL3_SHARED_LIB := $(PREFIX)/lib/libSDL3.dylib
    SDL3_DLL := $(PREFIX)/lib/libSDL3.dylib
else
    SDL3_SHARED_LIB := $(PREFIX)/lib/libSDL3.so
    SDL3_DLL := $(PREFIX)/lib/libSDL3.so
endif

ifeq ($(STATIC),1)
    ifeq ($(PLATFORM),macos)
        LINK_DEPS := $(PREFIX)/lib/libSDL3.a
        LINK_FLAGS := $(PREFIX)/lib/libSDL3.a \
            -L-framework -LCoreMedia \
            -L-framework -LCoreVideo \
            -L-framework -LCocoa \
            -L-weak_framework -LUniformTypeIdentifiers \
            -L-framework -LIOKit \
            -L-framework -LForceFeedback \
            -L-framework -LCarbon \
            -L-framework -LCoreAudio \
            -L-framework -LAudioToolbox \
            -L-framework -LAVFoundation \
            -L-framework -LFoundation \
            -L-framework -LGameController \
            -L-framework -LMetal \
            -L-framework -LQuartzCore \
            -L-weak_framework -LCoreHaptics \
            -L-lpthread -L-lm
    else ifeq ($(PLATFORM),windows)
        ifneq ($(wildcard $(PREFIX)/lib/SDL3-static.lib),)
            LINK_DEPS := $(PREFIX)/lib/SDL3-static.lib
            LINK_FLAGS := $(PREFIX)/lib/SDL3-static.lib \
                -Luser32.lib -Lgdi32.lib -Lwinmm.lib -Limm32.lib -Lole32.lib \
                -Loleaut32.lib -Lversion.lib -Luuid.lib -Ladvapi32.lib \
                -Lsetupapi.lib -Lshell32.lib -Lcfgmgr32.lib
        else
            LINK_DEPS := $(PREFIX)/lib/libSDL3.a
            LINK_FLAGS := $(PREFIX)/lib/libSDL3.a \
                -L-luser32 -L-lgdi32 -L-lwinmm -L-limm32 -L-lole32 \
                -L-loleaut32 -L-lversion -L-luuid -L-ladvapi32 \
                -L-lsetupapi -L-lshell32 -L-lcfgmgr32
        endif
    else
        # Linux static linking
        LINK_DEPS := $(PREFIX)/lib/libSDL3.a
        LINK_FLAGS := $(PREFIX)/lib/libSDL3.a -L-lpthread -L-ldl -L-lm
    endif
else
    # Dynamic linking
    LINK_DEPS := $(SDL3_SHARED_LIB)
    ifeq ($(PLATFORM),macos)
        RPATH_FLAGS := -L-rpath -L@executable_path -L-rpath -L@executable_path/../build/third-party/install/lib
    else ifeq ($(PLATFORM),linux)
        RPATH_FLAGS := -L-rpath -L'$$ORIGIN' -L-rpath -L'$$ORIGIN/../build/third-party/install/lib'
    else
        RPATH_FLAGS :=
    endif
    LINK_FLAGS := -L-L"$(PREFIX)/lib" -L-lSDL3 $(RPATH_FLAGS)
endif

# -----------------------------------------------------------------------------
# Primary Targets
# -----------------------------------------------------------------------------

.PHONY: all viewer test check bench benchmarks third-party third-party-clean \
        clean clean-all distclean vgc check-nophobos fmt fmt-check shaders dist help

all: viewer

viewer: $(VIEWER_BIN)

# -----------------------------------------------------------------------------
# Third-Party Dependencies (SDL3)
# -----------------------------------------------------------------------------

ifeq ($(FORCE),1)
.PHONY: $(SDL3_HEADER)
endif

third-party: $(SDL3_HEADER) $(PREFIX)/lib/libSDL3.a

$(PREFIX)/lib/libSDL3.a $(PREFIX)/lib/libSDL3.so $(PREFIX)/lib/libSDL3.dylib \
$(PREFIX)/lib/SDL3-static.lib $(PREFIX)/lib/SDL3.lib $(PREFIX)/lib/libSDL3.dll.a \
$(PREFIX)/bin/SDL3.dll $(SDL3_HEADER):
	@echo "==> Building third-party dependencies: SDL3 (shared + static, $(PLATFORM))..."
	$(MKDIR) $(BUILD_DIR)/third-party
	$(CMAKE) -S third-party/SDL3 -B $(BUILD_DIR)/third-party/SDL3 \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$(PREFIX)" \
		-DCMAKE_PREFIX_PATH="$(PREFIX)" \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DSDL_SHARED=ON -DSDL_STATIC=ON \
		-DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
	$(CMAKE) --build $(BUILD_DIR)/third-party/SDL3 --config Release --parallel $(JOBS)
	$(CMAKE) --install $(BUILD_DIR)/third-party/SDL3 --config Release
	@echo "==> SDL3 successfully installed in $(PREFIX)"

third-party-clean:
	$(RM) $(BUILD_DIR)/third-party

# -----------------------------------------------------------------------------
# C Object Compilation (Isolated in build/$(BUILD)/obj/)
# -----------------------------------------------------------------------------

$(OBJ_DIR)/nk_impl$(OBJ): src/gui/nk_impl.c $(SDL3_HEADER) | $(OBJ_DIR)
	@echo "==> Compiling $< [$(BUILD)]..."
	$(CC) $(C_FLAGS) -Ithird-party/Nuklear -Ithird-party/Nuklear/demo/sdl3_renderer -c $< $(C_OUT)$@

$(OBJ_DIR)/gpu_scene$(OBJ): src/gfx/gpu_scene.c src/gfx/shaders/scene_shaders.h $(SDL3_HEADER) | $(OBJ_DIR)
	@echo "==> Compiling $< [$(BUILD)]..."
	$(CC) $(C_FLAGS) -c $< $(C_OUT)$@

# -----------------------------------------------------------------------------
# Viewer Binary (Configuration-specific + Staged in bin/)
# -----------------------------------------------------------------------------

$(CONFIG_VIEWER_BIN): src/app.d $(D_SRCS) $(C_OBJS) $(LINK_DEPS) | $(CONFIG_BIN_DIR) $(OBJ_DIR)
	@echo "==> Building $@ [$(BUILD), static=$(STATIC), cpu=$(or $(TARGET_CPU),native)]..."
	$(LDC) $(D_MODULES) $(D_COMMON_FLAGS) $(D_OPT_FLAGS) $(D_CPU_FLAGS) $(D_SAN_FLAGS) \
		-od=$(OBJ_DIR) \
		src/app.d $(C_OBJS) \
		$(LINK_FLAGS) \
		-of=$@
ifeq ($(STATIC),0)
    ifeq ($(PLATFORM),windows)
	@if [ -f "$(PREFIX)/bin/SDL3.dll" ]; then $(CP) "$(PREFIX)/bin/SDL3.dll" $(CONFIG_BIN_DIR)/; fi
    else ifeq ($(PLATFORM),macos)
	@if [ -f "$(PREFIX)/lib/libSDL3.0.dylib" ]; then \
		$(CP) "$(PREFIX)/lib/libSDL3.0.dylib" $(CONFIG_BIN_DIR)/; \
		ln -sf libSDL3.0.dylib $(CONFIG_BIN_DIR)/libSDL3.dylib 2>/dev/null || true; \
	fi
    else
	@if [ -f "$(PREFIX)/lib/libSDL3.so" ]; then \
		$(CP) "$(PREFIX)/lib/libSDL3.so"* $(CONFIG_BIN_DIR)/ 2>/dev/null || true; \
	fi
    endif
endif

# User-facing binary staged in bin/
$(VIEWER_BIN): $(CONFIG_VIEWER_BIN) | $(BIN_DIR)
	@$(CP) $(CONFIG_VIEWER_BIN) $(BIN_DIR)/
ifeq ($(STATIC),0)
    ifeq ($(PLATFORM),windows)
	@if [ -f "$(CONFIG_BIN_DIR)/SDL3.dll" ]; then $(CP) "$(CONFIG_BIN_DIR)/SDL3.dll" $(BIN_DIR)/; fi
    else ifeq ($(PLATFORM),macos)
	@if [ -f "$(CONFIG_BIN_DIR)/libSDL3.0.dylib" ]; then \
		$(CP) "$(CONFIG_BIN_DIR)/libSDL3.0.dylib" $(BIN_DIR)/; \
		ln -sf libSDL3.0.dylib $(BIN_DIR)/libSDL3.dylib 2>/dev/null || true; \
	fi
    else
	@if [ -f "$(CONFIG_BIN_DIR)/libSDL3.so" ]; then \
		$(CP) "$(CONFIG_BIN_DIR)/libSDL3.so"* $(BIN_DIR)/ 2>/dev/null || true; \
	fi
    endif
endif
	@echo "==> Successfully staged $(VIEWER_BIN) [$(BUILD)]"

# -----------------------------------------------------------------------------
# Distribution Bundle (make dist)
# -----------------------------------------------------------------------------

DIST_NAME := shiro_viewer-$(PLATFORM)-$(ARCH)
DIST_BUNDLE := $(DIST_DIR)/$(DIST_NAME)

dist: $(VIEWER_BIN)
	@echo "==> Preparing standalone distribution bundle in $(DIST_BUNDLE)..."
	$(RM) $(DIST_BUNDLE) $(DIST_DIR)/$(DIST_NAME).tar.gz $(DIST_DIR)/$(DIST_NAME).zip
	$(MKDIR) $(DIST_DIR)
	$(MKDIR) $(DIST_BUNDLE)
	$(CP) $(VIEWER_BIN) $(DIST_BUNDLE)/
ifeq ($(STATIC),0)
    ifeq ($(PLATFORM),windows)
	@if [ -f "$(BIN_DIR)/SDL3.dll" ]; then $(CP) "$(BIN_DIR)/SDL3.dll" $(DIST_BUNDLE)/; fi
    else ifeq ($(PLATFORM),macos)
	@if [ -f "$(BIN_DIR)/libSDL3.0.dylib" ]; then \
		$(CP) "$(BIN_DIR)/libSDL3.0.dylib" $(DIST_BUNDLE)/; \
		ln -sf libSDL3.0.dylib $(DIST_BUNDLE)/libSDL3.dylib 2>/dev/null || true; \
	fi
    else
	@if [ -f "$(BIN_DIR)/libSDL3.so" ]; then \
		$(CP) "$(BIN_DIR)/libSDL3.so"* $(DIST_BUNDLE)/ 2>/dev/null || true; \
	fi
    endif
endif
	$(MKDIR) $(DIST_BUNDLE)/assets
	$(CP) assets/* $(DIST_BUNDLE)/assets/ 2>/dev/null || true
	$(CP) README.md $(DIST_BUNDLE)/
ifeq ($(PLATFORM),windows)
	@cd $(DIST_DIR) && cmake -E tar cf $(DIST_NAME).zip --format=zip $(DIST_NAME)
	@echo "==> Created $(DIST_DIR)/$(DIST_NAME).zip"
else
	@tar -czf $(DIST_DIR)/$(DIST_NAME).tar.gz -C $(DIST_DIR) $(DIST_NAME)
	@echo "==> Created $(DIST_DIR)/$(DIST_NAME).tar.gz"
endif

# -----------------------------------------------------------------------------
# Tests (Isolated in build/$(BUILD)/bin/ & obj/)
# -----------------------------------------------------------------------------

test: check

check: $(TEST_BIN)
	@echo "==> Running headless test suite [$(BUILD)]..."
	$(RUN_DIR)$(TEST_BIN) $(if $(filter 1,$(FULL)),--full,)

$(TEST_BIN): tests/test_runner.d $(TEST_SRCS) $(D_SRCS) | $(CONFIG_BIN_DIR) $(OBJ_DIR)
	@echo "==> Building test runner $(TEST_BIN)..."
	$(LDC) $(D_TEST_MODULES) $(D_COMMON_FLAGS) $(D_CPU_FLAGS) -g -unittest $(D_SAN_FLAGS) \
		-od=$(OBJ_DIR) \
		tests/test_runner.d -of=$@

# -----------------------------------------------------------------------------
# Benchmarks (Isolated in build/$(BUILD)/bench/ & obj/)
# -----------------------------------------------------------------------------

bench: benchmarks

benchmarks: $(BENCH_BINS)
	@echo "==> Running microbenchmarks [$(BUILD)]..."
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_propagation$(EXE)
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_wfc_solve$(EXE)
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_routes$(EXE)
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_td_tick$(EXE)
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_village_gen$(EXE)
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_village_gen$(EXE)
	$(RUN_DIR)$(CONFIG_BENCH_DIR)/bench_scale$(EXE) 8 $(SCALE_CELLS)

$(CONFIG_BENCH_DIR)/%$(EXE): benchmarks/%.d $(D_SRCS) | $(CONFIG_BENCH_DIR) $(OBJ_DIR)
	@echo "==> Building benchmark: $* [$(BUILD)]..."
	$(LDC) -O3 -release -boundscheck=off $(D_BENCH_MODULES) $(D_COMMON_FLAGS) $(D_CPU_FLAGS) \
		-od=$(OBJ_DIR) \
		$< -of=$@

# Run a specific benchmark (e.g. make bench-routes, make bench-scale BENCH_ARGS="8 10000 50000")
bench-%: $(CONFIG_BENCH_DIR)/bench_%$(EXE)
	$(RUN_DIR)$< $(BENCH_ARGS)

# Convenient hyphenated aliases
bench-td-tick: bench-td_tick
bench-wfc-solve: bench-wfc_solve

# -----------------------------------------------------------------------------
# Shaders
# -----------------------------------------------------------------------------

shaders:
	@echo "==> Rebuilding shaders..."
	./scripts/build_shaders.sh

# -----------------------------------------------------------------------------
# Static Verification & Code Quality (AGENTS.md Directives)
# -----------------------------------------------------------------------------

# -o- suppresses object file emission so vgc leaves zero .o files behind
vgc:
	@echo "==> Checking zero GC allocations in simulation hot paths (-vgc)..."
	$(LDC) -c -o- -vgc $(D_COMMON_FLAGS) \
		src/core/random.d src/core/bitset.d src/core/noise.d src/core/result.d src/core/json.d src/core/file.d \
		src/wfc/*.d src/td/*.d src/story/*.d src/village/*.d
	@echo "==> GC check passed: zero allocations detected."

check-nophobos:
	@echo "==> Checking for prohibited std.* imports..."
	@if grep -rn "import std\." src/ tests/; then \
		echo "ERROR: Phobos (std.*) imports found!"; exit 1; \
	else \
		echo "Clean: Zero std.* imports found."; \
	fi

fmt:
	@echo "==> Formatting D source files with dfmt..."
	find src tests benchmarks -name "*.d" -exec $(DFMT) -i {} +
	@echo "==> Formatting complete."

fmt-check:
	@echo "==> Verifying D source formatting..."
	@find src tests benchmarks -name "*.d" -exec $(DFMT) -i {} +
	@if [ -n "$$(git diff --name-only src tests benchmarks | grep '\.d$$')" ]; then \
		echo "ERROR: Files need formatting. Run 'make fmt'."; \
		git diff --name-only src tests benchmarks | grep '\.d$$'; \
		exit 1; \
	else \
		echo "Clean: All files match canonical formatting."; \
	fi

# -----------------------------------------------------------------------------
# Clean & Directory Rules
# -----------------------------------------------------------------------------

$(BUILD_DIR) $(CONFIG_DIR) $(OBJ_DIR) $(CONFIG_BIN_DIR) $(CONFIG_BENCH_DIR) $(BIN_DIR):
	$(MKDIR) $@

clean:
	@echo "==> Cleaning build artifacts for configuration [$(BUILD)]..."
	$(RM) $(CONFIG_DIR)
	$(RM) $(BIN_DIR)/shiro_viewer* $(BIN_DIR)/libSDL3* $(BIN_DIR)/SDL3.dll
	@echo "==> Clean complete for [$(BUILD)]."

clean-all:
	@echo "==> Cleaning all build configurations..."
	$(RM) $(BUILD_DIR)/release $(BUILD_DIR)/debug $(BUILD_DIR)/profile
	$(RM) $(BIN_DIR)
	$(RM) $(DIST_DIR)
	@echo "==> Clean all complete."

distclean: clean-all
	@echo "==> Removing entire build, bin, and dist directories (including third-party)..."
	$(RM) $(BUILD_DIR)
	$(RM) $(BIN_DIR)
	$(RM) $(DIST_DIR)
	@echo "==> Distclean complete."

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help:
	@echo "Shiro Tower Defense Engine - Available Targets:"
	@echo "  make                     - Build standalone viewer ($(VIEWER_BIN)) [$(BUILD)]"
	@echo "  make dist                - Package release bundle into $(DIST_DIR)/"
	@echo "  make test [FULL=1]       - Build and run headless unit & integration tests"
	@echo "  make bench               - Build and run all microbenchmarks"
	@echo "  make bench-<name>        - Run specific benchmark (e.g., bench-scale, bench-routes)"
	@echo "  make third-party         - Build vendored C dependencies (SDL3 via CMake)"
	@echo "  make vgc                 - Static GC allocation diagnostic on hot paths (-vgc)"
	@echo "  make check-nophobos      - Verify no Phobos (std.*) imports"
	@echo "  make fmt                 - Format all .d files using dfmt"
	@echo "  make fmt-check           - Check if .d files conform to dfmt formatting"
	@echo "  make shaders             - Recompile SPIR-V and MSL shaders"
	@echo "  make clean               - Remove build artifacts for active configuration ($(BUILD))"
	@echo "  make clean-all           - Remove all configuration builds (release, debug, profile)"
	@echo "  make distclean           - Remove entire build/, bin/, and dist/ directories"
	@echo ""
	@echo "Build Options:"
	@echo "  BUILD=release|debug|profile - Select configuration (default: release)"
	@echo "  DEBUG=1                  - Alias for BUILD=debug"
	@echo "  PROFILE=1                - Alias for BUILD=profile"
	@echo "  STATIC=1|0               - Static link SDL3 (1, default) or dynamic link (0)"
	@echo "  TARGET_CPU=<cpu>         - Target CPU microarchitecture (default: silvermont for x86_64)"
	@echo "  ASAN=1                   - Enable AddressSanitizer (-fsanitize=address)"
	@echo "  FULL=1                   - Run full integration test suite (1,000 islands)"
	@echo "  FORCE=1                  - Force rebuild of third-party dependencies"
	@echo "  SCALE_CELLS=\"...\"        - Custom cell counts for bench_scale (e.g. \"10000 50000\")"
	@echo "  BENCH_ARGS=\"...\"         - Custom arguments for individual bench-<name> target"
