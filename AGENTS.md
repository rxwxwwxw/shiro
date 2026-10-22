# AGENTS.md

Prime Directive: 1. Make it work. 2. Make it correct. 3. Make it fast. Those are the constant priorities. Ensure deterministic, verified code before optimizing. Always design systems to run efficiently on low-spec target hardware ("potato-tier" CPUs and integrated memory budgets).

---

## Repository Architecture & Core Directives

This project is a high-performance Tower Defense engine featuring procedurally generated hex-tile maps. The engine utilizes **druntime-only D**, retaining core runtime primitives (`object.d`, `core.*`, slices, delegates, associative arrays, and selective GC allocation during cold startup), while **strictly prohibiting Phobos (`std.*`)**.

All code authored, refactored, or reviewed by AI agents must uphold these mandatory architectural constraints:

1. **Zero Phobos (`std.*` is banned):** Never import `std.*`. Rely solely on `core.*` modules, runtime primitives, or repository-internal utility modules.
2. **Strict Model-View-Controller (MVC) Decoupling:** The simulation/game logic (Model) must remain strictly isolated from presentation (View via SDL3) and input routing (Controller). The Model must compile and execute completely headlessly without SDL3 or GPU dependencies.
3. **LDC Toolchain Exclusive:** The project targets the **LDC** compiler exclusively. Do not write or maintain DMD-specific workarounds. All builds, sanitizers, and diagnostic tooling run via `ldc2`.
4. **Target Platform Portability:** Code must build and execute cleanly on Linux (x86_64/AArch64), Windows (x86_64), and macOS (Apple Silicon/x86_64), with architectural awareness for future Android deployment. Operating system APIs must never be invoked directly without abstraction; use SDL3 subsystems or platform-agnostic `core.sys.*` bindings guarded by `version(...)`.
5. **Strict Dependency Budget (>5,000 LOC Threshold):** Minimize external dependencies. Third-party C or D libraries are permitted **only** when an in-house implementation would exceed ~5,000 lines of non-trivial domain code (e.g., SDL3 for cross-platform windowing/audio/input, SQLite for zero-dependency persistence). All third-party integrations must expose clean `@nogc nothrow` wrappers.
6. **Deterministic RAII Resource Management:** Manual cleanup routines are prohibited. Encapsulate all OS, SDL3 (e.g., `SDL_Window*`, `SDL_Renderer*`, `SDL_Texture*`), and file/memory handles inside RAII structs utilizing destructors (`~this()`) and disabled copy constructors (`@disable this(this);`).
7. **Exception-Free (`nothrow`):** Code must compile with `-fno-exceptions`. Stack unwinding is completely disabled. Runtime failures must propagate through explicit `Result!(T, E)` tagged unions or error codes.
8. **Zero GC in Hot Paths (`@nogc`):** The primary simulation loop, hex map traversal, pathfinding flow fields, creep update ticks, spatial partitioning queries, and rendering queues must be statically verified as `@nogc`.
9. **Colocated Unit Tests for Core Systems:** Every non-GUI module in `src/` (Model, procedural generation, math, data structures) must include colocated `unittest` blocks placed directly beneath the struct or function under test. GUI and rendering modules (View) are currently exempt from unit testing.
10. **Headless Integration Tests & Mandatory Timeouts:** Multi-subsystem tests, procedural map validation suites, and end-to-end combat simulations reside in `tests/`. Every integration test binary must execute headlessly with an explicit runtime timeout and memory ceiling.
11. **Benchmarking for Heavy Algorithms:** Computationally intensive components (procedural hex generation, flow-field pathfinding, line-of-sight calculation, spatial hashing) must have dedicated benchmarks to prevent performance regressions on low-spec hardware.
12. **Canonical Formatting (`dfmt`):** All `.d` source and test files must be formatted with `dfmt` before commit.
13. **Sanitizer & Leak Cleanliness:** All test binaries and headless simulations must run cleanly under AddressSanitizer (ASan), LeakSanitizer (LSan), and Valgrind Memcheck with zero memory leaks or memory access violations.

---

## 1. Architectural Layers & MVC Protocol

To guarantee that game simulations can execute without human interaction (for headless balancing, automated test passes, fuzzing, and AI replays), code must follow strict layer boundaries:


```

┌─────────────────────────────────────────────────────────────┐
│                       Controller                            │
│  - SDL3 Event Polling & Key/Mouse Translation              │
│  - Command Queue Dispatch (Headless AI or Human Input)      │
└──────────────────────────────┬──────────────────────────────┘
│ Dispatches Commands
▼
┌─────────────────────────────────────────────────────────────┐
│                         Model                               │
│  - Hex Grid State (Axial/Cubic coordinates)                 │
│  - Procedural Map Generation (WFC, flow fields, noise)      │
│  - Tower / Creep State Machines & Spatial Partitioning      │
│  - Deterministic Tick Loop (@nogc nothrow pure)             │
│  - ZERO SDL3 / GPU / Window dependencies                    │
└──────────────────────────────┬──────────────────────────────┘
│ Reads Immutable State
▼
┌─────────────────────────────────────────────────────────────┐
│                          View                               │
│  - SDL3 2D Render Pipeline / Sprite Batching                │
│  - Camera Transform (Screen <-> Hex World Space)            │
│  - Audio & UI Presentation                                  │
│  - Unit tests NOT required for this layer                   │
└─────────────────────────────────────────────────────────────┘

```

### 1.1. Model Invariants
- The Model must never import SDL3 modules, call windowing APIs, or query hardware display state.
- Model ticks must be 100% deterministic given a random seed and an ordered command input stream.
- All hex grid calculations must use axial or cube coordinate systems ($q, r, s$ where $q + r + s = 0$) with integer math or fixed-point values where determinism across platforms is required.

### 1.2. View & Controller Isolation
- The View queries state from the Model via read-only interfaces or value-type state snapshots. The View never alters Model state directly.
- The Controller translates SDL3 events (`SDL_Event`) into domain commands (e.g., `PlaceTowerCommand`, `UpgradeTowerCommand`, `SetGameSpeedCommand`) and queues them into the Model tick queue.
- Headless test runners replace the SDL3 Controller with an automated script runner or bot agent.

---

## 2. Dependencies & Third-Party Library Policy

1. **The 5k LOC Rule:** Write domain logic internally. Introduce external C/D dependencies only when the problem domain is excessively complex and maintenance would divert from engine development (e.g., SDL3, SQLite, zstd).
2. **Minimal Wrapper Overhead:** All external C libraries must be bound through raw `extern (C)` signatures with lightweight RAII D struct wrappers.
3. **No Unchecked Allocations:** External libraries that allocate must allow overriding the memory allocator with custom arena or static buffer allocators where supported.

---

## 3. Code Style & Canonical Formatting

All `.d` files must strictly conform to the repository `.dfmt` configuration. 

### 3.1. Formatting Execution
```bash
find src tests benchmarks -name "*.d" -exec dfmt -i {} +

```

### 3.2. Baseline `.dfmt` Configuration

```ini
dfmt_align_switch_statements=true
dfmt_brace_style=otbs
dfmt_compact_labeled_switch_statements=true
dfmt_indent_size=4
dfmt_indent_style=space
dfmt_soft_max_line_length=100
dfmt_outdent_attributes=true
dfmt_space_after_cast=false
dfmt_split_operator_at_line_end=false

```

---

## 4. Error Handling Protocol

### 4.1. Expected Errors via `Result!(T, E)`

Expected operational failures (file not found, corrupted map seed, network/socket timeout, full command queue) must never throw exceptions. Use a zero-allocation `Result!(T, E)` tagged union:

```d
enum EngineError : int {
    None = 0,
    InvalidHexCoordinates,
    MapSeedExhausted,
    BufferOverflow,
    ResourceNotFound,
    InitializationFailed
}

struct Result(T, E = EngineError) {
    private union {
        T _value;
        E _error;
    }
    private bool _isOk;

    static Result ok(T val) @nogc nothrow {
        Result r;
        r._isOk = true;
        r._value = val;
        return r;
    }

    static Result err(E err) @nogc nothrow {
        Result r;
        r._isOk = false;
        r._error = err;
        return r;
    }

    bool isOk() const @nogc nothrow pure @safe { return _isOk; }
    inout(T) value() inout @nogc nothrow @trusted { assert(_isOk); return _value; }
    inout(E) error() inout @nogc nothrow @trusted { assert(!_isOk); return _error; }
}

```

### 4.2. Invariants & Fatal Failures

Use standard `assert(...)` for invariants, mathematical preconditions, and internal consistency checks. Assertions remain active in debug/testing builds, abort execution deterministically, and are fully compatible with `nothrow` functions under LDC.

---

## 5. Performance, Memory & "Potato" Hardware Budget

Target hardware includes legacy low-power systems (dual-core x86_64, integrated Intel HD/Iris graphics, low memory envelopes).

### 5.1. Allocation Constraints in Hot Paths

* **Zero Heap Allocations:** Frame rendering loops, map path queries, tower targeting evaluations, and creep movement updates must not allocate through the GC (`@nogc`).
* **Pre-Allocated Arenas & Free Lists:** Use contiguous array buffers, fixed-capacity ring buffers, or stack-backed storage for dynamic entities.
* **Cache-Conscious Hex Grids:** Store hex data in contiguous Structure of Arrays (SoA) or flat Array of Structures (AoS) keyed by axial index lookups. Avoid pointer-chasing node graphs.

### 5.2. Mandatory Benchmarks

Any computationally heavy algorithm—specifically:

* Procedural hex generation (WFC, erosion passes, terrain noise).
* Multi-source/multi-sink pathfinding and vector flow fields.
* Spatial hash partitioning and collision/range queries.

Must include a microbenchmark located in `benchmarks/` tracking throughput and microsecond latency per tick.

---

## 6. Compiler Commands & Verification (LDC)

### 6.1. GC Allocation Diagnostics (`-vgc`)

Verify that simulation modules and hot paths emit zero hidden heap allocations:

```bash
ldc2 -c -vgc -defaultlib=druntime-ldc src/model/hex_grid.d

```

*Any compiler message indicating closure creation, array reallocation, or implicit GC allocation in hot paths is a hard build failure.*

### 6.2. Standard Compilation Flags

```bash
# Debug & Unit Tests (Headless)
ldc2 -defaultlib=druntime-ldc -fno-exceptions -g -unittest -run tests/test_runner.d

# Optimized Headless Simulation / Release Build
ldc2 -defaultlib=druntime-ldc -fno-exceptions -O3 -release -boundscheck=safe src/app.d -of=bin/td_engine

# Cross-compilation target check (example: AArch64 macOS or Linux)
ldc2 -mtriple=aarch64-linux-gnu -defaultlib=druntime-ldc -fno-exceptions -c src/model/simulation.d

```

---

## 7. Sanitizers, Leak Detection & Validation Protocol

### 7.1. AddressSanitizer & LeakSanitizer (LDC)

All unit tests and headless simulation passes must run under ASan and LSan:

```bash
ldc2 -fsanitize=address -defaultlib=druntime-ldc -fno-exceptions -g -unittest -run tests/test_runner.d

```

### 7.2. Valgrind Memcheck

For verification of uninitialized reads, memory alignment, and complete reclamation:

```bash
ldc2 -g -O0 -defaultlib=druntime-ldc -fno-exceptions tests/test_runner.d -of=bin/test_runner

valgrind \
  --tool=memcheck \
  --leak-check=full \
  --show-leak-kinds=all \
  --track-origins=yes \
  --errors-for-leak-kinds=definite,indirect \
  --error-exitcode=1 \
  ./bin/test_runner

```

---

## 8. Pre-Submission Checklist for AI Agents

Before submitting code, generating patches, or opening a PR, complete every item:

* [ ] **Zero `std.*` Imports:** Ran `grep -rn "import std\." src/` and verified 0 hits.
* [ ] **Strict MVC Separation:** Verified that no module in `src/model/` imports SDL3, GPU/graphics headers, or windowing logic.
* [ ] **LDC Compatibility:** Code compiles cleanly with `ldc2 -defaultlib=druntime-ldc -fno-exceptions` with zero warnings.
* [ ] **Formatted with `dfmt`:** Executed `find src tests benchmarks -name "*.d" -exec dfmt -i {} +`.
* [ ] **Colocated Core Unit Tests:** Every new or modified function in `src/model/`, `src/math/`, and `src/core/` has an adjacent `unittest` block directly below it (View/GUI files are exempt).
* [ ] **Headless Integration Test Validation:** Automated simulations run without GUI dependencies and complete within the required timeout limits.
* [ ] **Hot Paths are `@nogc` & `nothrow`:** Performance-critical simulation routines are verified via `ldc2 -vgc`.
* [ ] **RAII Encapsulation:** All SDL3 resources, OS handles, and allocated buffers use RAII wrappers with `@disable this(this);`.
* [ ] **Performance & Benchmarking:** Algorithms for hex generation, flow fields, or collision detection have benchmark coverage and satisfy the low-spec performance budget.
* [ ] **Sanitizer Clean:** Executed clean runs under ASan/LSan and Valgrind Memcheck with exit code 0.


---

### Immediate Verification Steps

To validate this updated configuration against your existing codebase:

1. **Verify No Phobos Imports:**
   ```bash
   grep -rn "import std\." src/ tests/

```

2. **Confirm LDC No-Exception Druntime Compilation:**
```bash
ldc2 -defaultlib=druntime-ldc -fno-exceptions -c src/model/hex_grid.d

```


3. **Execute Static GC Allocation Check on Simulation Modules:**
```bash
ldc2 -c -vgc -defaultlib=druntime-ldc src/model/*.d

```


4. **Run Headless Unit Tests:**
```bash
ldc2 -defaultlib=druntime-ldc -fno-exceptions -g -unittest -run tests/test_runner.d

```
