# Tower Defense Engine (Dlang + SDL3)

An agent-oriented technical specification, repository roadmap, and execution guide for constructing a high-performance Tower Defense (TD) engine in Dlang using SDL3, companion SDL libraries, and Nuklear.

---

## 1. Primary Mission Objective

The immediate priority for this repository is **The Hex-Map Wave Function Collapse (WFC) Port**.

Agents working in this codebase must analyze the existing JavaScript reference implementation located in `./third-party/Hex-Map-WFC` and port its data structures, constraint solvers, tile adjacency rules, and generation mechanics into idiomatic, statically typed, performant Dlang. This foundation will serve as the procedural terrain and navigation substrate for the subsequent TD engine subsystems (pathfinding, creep flow, tower placement, spatial audio, and combat).

---

## 2. Repository Layout

```
.
├── Makefile                       # Cross-platform GNU Makefile (macOS, Linux, Windows 10)
├── README.md                      # This specification document
├── scripts/
│   ├── build_shaders.sh           # Recompiles SPIR-V and MSL shaders
│   ├── build_third_party.sh       # Platform build script for C dependencies (POSIX)
│   ├── build_third_party.bat      # Platform build script for C dependencies (Windows)
│   ├── build_viewer.sh            # Build script for map viewer (POSIX)
│   └── build_viewer.bat           # Build script for map viewer (Windows)
├── src/
│   ├── app.d                      # Entry point & engine loop
│   ├── bindings/                  # D-to-C bindings (extern(C) / ImportC headers)
│   │   ├── sdl3/                  # SDL3 core, image, mixer, net, ttf
│   │   └── nuklear/               # Nuklear immediate-mode GUI bindings
│   ├── core/                      # Engine math, memory, data structures, event queue
│   ├── gfx/                       # SDL3 render pipeline, textures, camera, viewport
│   ├── gui/                       # Nuklear integration & debug overlay
│   ├── wfc/                       # Wave Function Collapse solver & hex tile logic
│   └── td/                        # Tower defense gameplay subsystems (future phase)
└── third-party/
    ├── Hex-Map-WFC/               # [REFERENCE] JavaScript WFC hex tile generator
    ├── Nuklear/                   # Immediate-mode GUI (single-header C)
    ├── SDL3/                      # Core multimedia library (C)
    ├── SDL3_image/                # Image decoding library (C)
    ├── SDL3_mixer/                # Audio mixing library (C)
    ├── SDL3_net/                  # Cross-platform networking (C)
    └── SDL3_ttf/                  # Font rendering library (C)
```

---

## 3. Technology Stack & Technical Constraints

| Component | Choice | Rationale & Requirements |
| :--- | :--- | :--- |
| **Language** | **D (Dlang)** | Modern, fast, supports both garbage collection and manual memory management (`@nogc`). Default compiler target: LDC or DMD. |
| **Build Tool** | **DUB** / **CMake** | DUB handles D dependency resolution and compilation. CMake or shell build scripts compile native C dependencies in `./third-party`. |
| **Windowing & Input** | **SDL3** (`./third-party/SDL3`) | The next-generation SDL API. Modern event polling, multi-window, GPU driver abstraction. |
| **Media Companions** | `SDL3_image`, `SDL3_mixer`, `SDL3_net`, `SDL3_ttf` | Standard SDL3 extensions for asset loading, sound effects/music, networking, and font rasterization. |
| **Debug UI** | **Nuklear** (`./third-party/Nuklear`) | Header-only ANSI C GUI. Lightweight, zero dependencies, binds cleanly via `extern(C)` or D's `ImportC`. |
| **Reference Code** | `Hex-Map-WFC` | Node.js / Browser-based JS project containing hex adjacency definitions, collapse loops, and tile assets. |

---

## 4. Native Dependency Compilation Protocol

### Compilation Strategy
All third-party libraries must be compiled as either static (`.a` / `.lib`) or shared (`.so` / `.dylib` / `.dll`) libraries per target architecture:

1. **SDL3 & Extensions (`SDL3`, `SDL3_image`, `SDL3_mixer`, `SDL3_net`, `SDL3_ttf`)**:
   - Utilize CMake via scripts in `./scripts/`:
     ```bash
     cmake -S third-party/SDL3 -B build/third-party/SDL3 -DCMAKE_BUILD_TYPE=Release
     cmake --build build/third-party/SDL3 --config Release
     ```
   - Build companion libraries similarly, pointing to the built SDL3 CMake config directory via `-DSDL3_DIR=...`.
2. **Nuklear**:
   - Compile a minimal translation unit (e.g., `nuklear_impl.c`) with `#define NK_IMPLEMENTATION` and `#define NK_SDL3_IMPLEMENTATION` or link the C compilation step via DUB's `cSourcePaths`.
3. **Linkage in DUB**:
   - Specify `lflags` and `libs` in `dub.json` pointing to `build/third-party/lib` or system library paths.

---

## 5. Dlang Binding Strategy

Agents must adhere to one of the following binding patterns for SDL3 and Nuklear:

1. **Direct `extern(C)` Modules (Recommended)**:
   - Construct typed interfaces under `src/bindings/sdl3/` matching SDL3 function prototypes and structs.
   - SDL3 changed many SDL2 function signatures (e.g., uses 64-bit coordinate spaces or floats for 2D geometry like `SDL_FRect`, standardized return codes using `bool` instead of `0`/`-1`). Ensure bindings match SDL3 definitions exactly.
2. **ImportC (Alternative for Headers)**:
   - Use D's native C preprocessor and parser (`importC`) where compatible. For complex macro-heavy headers like SDL3 or Nuklear, write clean wrapper C files exporting the symbols needed by D.

---

## 6. Hexagonal Wave Function Collapse (WFC) Architecture

### 6.1 Reference Extraction (`./third-party/Hex-Map-WFC`)
Agents must inspect the reference implementation to extract:
1. **Grid Geometry & Layout**:
   - Pointy-topped vs. Flat-topped hexagonal orientation.
   - Coordinate system: Axial coordinates $(q, r)$ or Cube coordinates $(q, r, s)$ where:
     $$q + r + s = 0$$
   - Neighbor direction vectors (6 neighbors per tile).
2. **Tile Definitions & Symmetry**:
   - Tile prototypes and their rotational variations ($0^\circ, 60^\circ, 120^\circ, 180^\circ, 240^\circ, 300^\circ$).
   - Socket matching rules (edge identifiers) or adjacency matrices (which tile edge connects to which neighboring edge).
   - Tile weights/frequencies for entropy calculation.
3. **Solver Loop**:
   - Observe how conflicts/contradictions are resolved (backtracking stack vs. full map restart).

### 6.2 Dlang WFC Module Design (`src/wfc/`)
Design the D implementation around these components:

* `hex.d`: Vector math, cube coordinate manipulation, distance metrics, neighbor lookups, and hex-to-pixel/pixel-to-hex conversion functions.
* `tile.d`: Definition of tiles, sockets, rotations, weights, and rendering sprite identifiers.
* `model.d`:
  - **Superposition Array**: Grid of cells where each cell holds a bitset (`std.bitmanip.BitArray` or fixed integer mask) of remaining possible tile IDs.
  - **Entropy Tracker**: Selects the non-collapsed cell with the lowest Shannon entropy:
    $$H(c) = \log\left(\sum_{t \in C} w_t\right) - \frac{\sum_{t \in C} w_t \log w_t}{\sum_{t \in C} w_t}$$
  - **Propagator**: An explicit propagation stack or queue. When a cell collapses or loses a possibility, its 6 neighbors are checked against constraint tables, pushing affected cells into the queue.
  - **Contradiction Handling**: Return a `Result` type or error code indicating contradiction, triggering a grid restart or stepping back down a snapshot stack.


---

## Map Viewer (SDL3 + Nuklear)

A pseudo-3D viewer for the generated maps. Its side panel sets the layout (rectangle or island), size, grid radius, seed and decoration parameters.

### Building with Make (macOS, Linux, Windows 10)

```bash
# Prerequisites: cmake, ldc2, and a C compiler (clang/gcc/cc/msvc)
make                 # builds SDL3 (if needed) and standalone bin/shiro_viewer (STATIC=1 default)
make dist            # packages standalone release tarball/zip in dist/
make test            # runs unit and integration test suite
make bench           # runs microbenchmarks
make help            # lists all targets and build options
```

#### Build & Distribution Options
- `STATIC=1` (default): Statically links SDL3 into a standalone single-file binary with zero external dynamic library dependencies (permitted by SDL3's zlib and druntime's Boost licenses).
- `STATIC=0`: Dynamically links SDL3, automatically placing the shared library alongside the executable in `bin/` with RPATH (`$ORIGIN` on Linux, `@executable_path` on macOS) for portable folder distribution.
- `TARGET_CPU=silvermont` (default on x86_64 Linux/Windows): Tunes instructions for Intel Braswell (Airmont) and newer CPUs (enabling hardware `POPCNT`, `SSE4.2`, and `SSSE3` while strictly avoiding `AVX` to run safely on low-spec/Atom hardware).
- `BUILD=release` (default) or `BUILD=debug` / `DEBUG=1`.

Alternatively, platform-specific scripts are available:
- **macOS / Linux**: `scripts/build_third_party.sh && scripts/build_viewer.sh [--static]`
- **Windows 10**: `scripts\build_third_party.bat && scripts\build_viewer.bat [--static]`

### Running the Viewer

```bash
bin/shiro_viewer --layout island --radius 8 --rings 2 --seed 7
bin/shiro_viewer --cells 20000 --aspect 16:9 --radius 6
bin/shiro_viewer --cols 120 --rows 60 --screenshot map.bmp   # render one frame and exit
```

Controls: drag to pan, wheel or `+`/`-` to zoom, `R` new seed, `F` fit, `O` cell outlines, `Tab` toggle panel, `Esc` quit.

The viewer starts in the village hub (below); add `--scene td` to go straight to a tower defense map, as the map examples above intend.

### The village

Làng Sương is a seeded WFC village (`src/village/`): a west gate, a plaza with a well, a đình hall, a market, a temple and a smithy. These are pinned as anchors, roads link them, and the terrain around them is generated fresh for each `--seed`. Walk with `WASD` or the arrow keys and talk with `E` (also `Space` / `Enter`). `1`-`6` pick a choice, and `Esc` leaves a conversation. The gate stays shut until the elder agrees. Walking out of it starts a tower defense run shaped by your choices: the priestess can unlock tesla towers or weaken creeps, and the smith can unlock flame towers or give gold. When the run ends, `Enter` (or the panel button) brings you home to a scene that depends on how it went.

The story is data: `assets/story/village.json` (speakers, NPC homes, dialogue nodes with conditions and effects, triggers), compiled by `src/story/`. Art comes from `scripts/blender/village_props.py` (props) and `village_chars.py` (walk sheets, portraits, standing figures); every piece is optional.

```bash
bin/shiro_viewer --seed 3 --talk elder --screenshot talk.bmp   # open a conversation and render it
bin/shiro_viewer --story my_story.json                         # play another story file
```

### Playing tower defense

Every map with roads is a game. You start with 300 gold and 20 lives, and there are 30 waves. A wave starts when its countdown ends; calling it early (`Space`) pays a gold for each second skipped.

| Tower | Lv1 / Lv2 | Specializations (choose at Lv2) |
| :--- | :--- | :--- |
| Arrow (`1`) | fast single shots | **Longbow**: huge range, pierces armor. **Volley**: three arrows at once |
| Cannon (`2`) | shells that splash | **Cluster**: throws 4 bomblets. **Siege**: massive blast, shreds armor |
| Frost (`3`) | shards that slow an area | **Blizzard**: pulses to slow everything in range. **Shatter**: chilled creeps take +40% |
| Tesla (`4`) | chain lightning, ignores armor | **Storm**: arcs through 9 creeps. **Overload**: one huge bolt that stuns |
| Flame (`5`) | short burning cone | **Inferno**: wide cone, long burn. **Napalm**: leaves burning ground |
| Mine (`6`) | +25 / +60 gold per wave | only on gold veins |

Special tiles:
- **Gold veins** (gold rocks) take mines only.
- **Ley stones** (cyan rocks) give a tower +25% damage.
- **High ground** adds 12% range per level above the nearest road, up to +36%.

The creeps are Grunts, fast Runners, armored Brutes, Swarmlings that come in packs, and a Boss every 10th wave.

Game keys:
- Click places the tower you picked; otherwise it selects.
- Right click cancels building.
- `U` upgrades to Lv2; `Q` / `E` pick a specialization.
- `Del` sells for 70%; `T` cycles targeting (first / strongest / closest).
- `P` pauses; `,` / `.` change speed (1-3x); `B` lets the scripted bot play.

`bin/shiro_viewer --scene td --bot --ticks 6000 --screenshot td.bmp` renders a bot game partway through. The rules live in `src/td/` (headless and deterministic). `make test` or `tests/run_tests.sh` plays whole bot games, and `make bench-td-tick` or `benchmarks/bench_td_tick.d` times the tick. The project can be built via `make` on macOS, Linux, and Windows 10, or using the platform scripts in `scripts/`.
