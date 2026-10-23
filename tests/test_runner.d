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

import core.runtime : Runtime, UnitTestResult;
import core.stdc.stdio : printf;
import wfc.rules;
import tests.harness;
import tests.test_wfc_multi_grid;
import tests.test_wfc_single_grid;
import tests.tileset_audit;
import tests.test_routes;
import tests.test_td_sim;
import tests.test_dialogue;
import tests.test_village;

// Pull every module's unit tests into the build.
import core.bitset, core.noise, core.random, core.result, core.json, core.file;
import story.pool, story.value, story.state, story.program, story.syntax, story.compile, story.vm, story.td_link;
import village.walk, village.plan, village.world, village.bot;
import wfc.cell, wfc.decorations, wfc.grid_connector, wfc.hex, wfc.map_generator, wfc.map_session,
    wfc.recovery, wfc.road_rules, wfc.placement, wfc.routes, wfc.passability, viewer.cli,
    viewer.commands, gfx.iso, gfx.camera, gfx.pick, gfx.hex_mesh, wfc.solver, wfc.tile_data,
    wfc.tile_map, td.defs, td.spatial, td.waves, td.board, td.game, td.bot, wfc.reveal, wfc.terrain;

/// Run integration main after the unit tests (the default under -unittest is tests only).
extern (C) __gshared string[] rt_options = ["testmode=run-main"];

/// Runs every module's unit tests except the vendored parser generator's (its exhaustive suite
/// runs on its own via `make test-npegged`; under ASan it alone exceeds the memory ceiling).
private UnitTestResult engineUnitTests() {
    UnitTestResult r;
    foreach (m; ModuleInfo) {
        if (m is null || m.unitTest is null)
            continue;
        const n = m.name;
        if (n.length >= 8 && n[0 .. 8] == "npegged.")
            continue;
        r.executed++;
        m.unitTest()();
        r.passed++;
    }
    r.runMain = true;
    r.summarize = true;
    return r;
}

shared static this() {
    Runtime.extendedModuleUnitTester = &engineUnitTests;
}

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

    printf("tower defense (%s)\n", full ? "full".ptr : "quick".ptr);
    tests.test_td_sim.run(rep, full ? 20 : 3);
    tests.test_td_sim.runReveal(rep, full ? 20 : 6);

    printf("story\n");
    tests.test_dialogue.run(rep);
    printf("village (%s)\n", full ? "full".ptr : "quick".ptr);
    tests.test_village.run(rep, full ? 40 : 6);

    rep.check(withinMemory(memoryCeilingMiB, "integration"), "peak memory under ceiling");
    printf("integration: %d passed, %d failed, peak RSS %d MiB (ceiling %d MiB, timeout %d s)\n",
            cast(int)rep.passed, cast(int)rep.failed, cast(int)peakRssMiB(),
            cast(int)memoryCeilingMiB, cast(int)timeoutSeconds);
    flush();
    return rep.failed == 0 ? 0 : 1;
}
