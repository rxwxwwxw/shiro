// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Integration: solve a single radius-8 grid (217 cells) across many seeds.
module tests.test_wfc_single_grid;

import core.stdc.stdio : printf;
import core.random : Random;
import wfc.hex;
import wfc.rules;
import wfc.solver;
import tests.harness : Report;

enum int gridRadius = 8;

private bool consistent(const(AdjacencyRules)* rules, const(PlacedTile)[] tiles) @nogc nothrow @trusted {
    foreach (ref a; tiles) {
        immutable ia = rules.stateId(a.state.tile, a.state.rotation, a.state.level);
        foreach (d; 0 .. numHexDirs) {
            immutable nc = a.coord.neighbor(cast(HexDir)d);
            foreach (ref b; tiles) {
                if (b.coord != nc)
                    continue;
                immutable ib = rules.stateId(b.state.tile, b.state.rotation, b.state.level);
                immutable ea = rules.stateEdges[ia][d];
                immutable eb = rules.stateEdges[ib][opposite(cast(HexDir)d)];
                if (!edgesCompatible(ea.type, ea.level, eb.type, eb.level))
                    return false;
            }
        }
    }
    return true;
}

void run(const(AdjacencyRules)* rules, ref Report rep, uint seeds) @nogc nothrow @trusted {
    auto solver = Solver(rules);
    CubeCoord[maxSolveCells] cells;
    immutable n = cubeCoordsInRadius(CubeCoord(0, 0, 0), gridRadius, cells[]);
    size_t solved = 0, consistentCount = 0;
    long backtracks = 0;
    foreach (seed; 1 .. seeds + 1) {
        auto rng = Random(seed);
        auto r = solver.solve(cells[0 .. n], null, null, rng);
        if (!r.isOk)
            continue;
        solved++;
        backtracks += r.value.backtracks;
        PlacedTile[maxSolveCells] placed;
        immutable np = solver.extract(placed[]);
        if (np == n && consistent(rules, placed[0 .. np]))
            consistentCount++;
    }
    printf("  single grid: %d/%d solved, %d consistent, %d backtracks total\n", cast(int)solved,
            cast(int)seeds, cast(int)consistentCount, cast(int)backtracks);
    rep.check(solved == seeds, "single grid: 100% solve rate");
    rep.check(consistentCount == seeds, "single grid: every edge matches");
}
