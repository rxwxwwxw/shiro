// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Central headless test runner (unit tests, then integration suites). Importing the src modules pulls their colocated unit tests into
// the build (compile with -i -unittest; our core.* modules need explicit -i= because
// the bare -i skips the druntime `core` package); main then runs the integration suites under an explicit
// wall-clock timeout and peak-memory ceiling.
//
//   ldc2 -i=wfc -i=tests -i=core.bitset -i=core.noise -i=core.random -i=core.result -I. -Isrc -defaultlib=druntime-ldc -fno-exceptions -g -unittest -run tests/test_runner.d
//   ... -run tests/test_runner.d -- --full     (1,000 islands; slow)
module tests.test_runner;

import core.stdc.stdio : printf;
import wfc.rules;
import tests.harness;
import tests.test_wfc_multi_grid;
import tests.test_wfc_single_grid;
import tests.tileset_audit;
import tests.test_routes;

// Pull every module's unit tests into the build.
import core.bitset, core.noise, core.random, core.result;
import wfc.cell, wfc.decorations, wfc.grid_connector, wfc.hex, wfc.map_generator, wfc.map_session,
    wfc.recovery, wfc.road_rules, wfc.placement, wfc.routes, wfc.passability, viewer.cli,
    viewer.commands, gfx.iso, gfx.camera, gfx.pick, gfx.hex_mesh, wfc.solver, wfc.tile_data, wfc.tile_map;

/// Run integration main after the unit tests (the default under -unittest is tests only).
extern (C) __gshared string[] rt_options = ["testmode=run-main"];

enum uint timeoutSeconds = 900;
enum size_t memoryCeilingMiB = 256;

__gshared AdjacencyRules rules;

int main(string[] args) {
    setTimeout(timeoutSeconds);
    bool full = false;
    foreach (a; args[1 .. $])
        if (a == "--full")
            full = true;

    AdjacencyRules.build(rules);
    Report rep;

    printf("tileset audit\n");
    tests.tileset_audit.run(rules, rep, false);
    printf("single grid (%s)\n", full ? "full".ptr : "quick".ptr);
    tests.test_wfc_single_grid.run(&rules, rep, full ? 1000 : 100);
    printf("multi grid (%s)\n", full ? "full".ptr : "quick".ptr);
    tests.test_wfc_multi_grid.run(&rules, rep, full ? 1000 : 50, full ? 20 : 3);

    printf("routes (%s)\n", full ? "full".ptr : "quick".ptr);
    tests.test_routes.run(rep, full ? 40 : 5);

    rep.check(withinMemory(memoryCeilingMiB, "integration"), "peak memory under ceiling");
    printf("integration: %d passed, %d failed, peak RSS %d MiB (ceiling %d MiB, timeout %d s)\n",
            cast(int)rep.passed, cast(int)rep.failed, cast(int)peakRssMiB(),
            cast(int)memoryCeilingMiB, cast(int)timeoutSeconds);
    flush();
    return rep.failed == 0 ? 0 : 1;
}
