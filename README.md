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
├── README.md                      # This specification document
├── dub.json / dub.sdl             # DUB package definition
├── scripts/
│   ├── build_third_party.sh       # Platform build script for C dependencies (POSIX)
│   └── build_third_party.bat      # Platform build script for C dependencies (Windows)
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

```bash
brew install cmake                 # or: sudo apt install cmake
scripts/build_third_party.sh       # builds third-party/SDL3 into build/third-party/install
scripts/build_viewer.sh            # builds bin/shiro_viewer (--debug, --asan)
bin/shiro_viewer --layout island --radius 8 --rings 2 --seed 7
bin/shiro_viewer --cells 20000 --aspect 16:9 --radius 6
bin/shiro_viewer --cols 120 --rows 60 --screenshot map.bmp   # render one frame and exit
```

Controls: drag to pan, wheel or `+`/`-` to zoom, `R` new seed, `F` fit, `O` cell outlines, `Tab` toggle panel, `Esc` quit.

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

`bin/shiro_viewer --bot --ticks 6000 --screenshot td.bmp` renders a bot game partway through. The rules live in `src/td/` (headless and deterministic). `tests/run_tests.sh` plays whole bot games, and `benchmarks/bench_td_tick.d` times the tick. The POSIX scripts are the only build path for now; a Windows `.bat` hasn't been written yet.
