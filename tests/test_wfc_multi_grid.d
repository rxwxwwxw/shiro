// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Integration: full 19-grid islands and 16:9 rectangular maps, verifying every grid boundary.
module tests.test_wfc_multi_grid;

import core.stdc.stdio : printf;
import core.random : Random;
import wfc.grid_connector;
import wfc.hex;
import wfc.map_generator;
import wfc.rules;
import wfc.solver;
import wfc.tile_map;
import tests.harness : Report;

/// Counts adjacent solved pairs whose edges do not match (pairs touching a mountain are the
/// deliberately masked seams and are returned separately).
struct SeamReport {
    size_t mismatches;
    size_t maskedByMountain;
    size_t unsolved;
}

SeamReport checkSeams(const(AdjacencyRules)* rules, ref const TileMap map) @nogc nothrow @trusted {
    SeamReport s;
    foreach (row; 0 .. map.rect.rows)
        foreach (col; 0 .. map.rect.cols) {
            immutable c = offsetToCube(col, row);
            immutable a = map.get(c);
            if (a < 0) {
                s.unsolved++;
                continue;
            }
            foreach (d; 0 .. numHexDirs) {
                immutable n = c.neighbor(cast(HexDir)d);
                immutable b = map.get(n);
                if (b < 0)
                    continue;
                immutable ea = rules.stateEdges[a][d];
                immutable eb = rules.stateEdges[b][opposite(cast(HexDir)d)];
                if (edgesCompatible(ea.type, ea.level, eb.type, eb.level))
                    continue;
                if (map.isMountain(c) || map.isMountain(n))
                    s.maskedByMountain++;
                else
                    s.mismatches++;
            }
        }
    return s;
}

/// 19-grid islands (two rings of radius-8 grids), many seeds.
void runIslands(const(AdjacencyRules)* rules, ref Report rep, uint seeds) @nogc nothrow @trusted {
    GridCoord center;
    MapRect rect;
    fitCluster(2, 8, center, rect);
    GridCoord[19] grids;
    immutable ng = clusterGrids(center, 2, grids[]);
    auto solver = Solver(rules);

    size_t perfect = 0, withMountains = 0;
    size_t cells = 0, dropped = 0, localWfc = 0;
    foreach (seed; 1 .. seeds + 1) {
        auto map = TileMap(rect);
        auto rng = Random(seed);
        immutable st = generateGrids(map, grids[0 .. ng], 8, solver, rng, GenOptions(0, false));
        immutable seams = checkSeams(rules, map);
        cells = map.countSolved;
        dropped += st.recovery.dropped;
        localWfc += st.recovery.localAttempts;
        if (st.gridsFailed == 0 && seams.unsolved == rect.cellCount - cells && seams.mismatches == 0
                && cells == 19 * cellsInRadius(8))
            perfect++;
        if (map.countMountains > 0)
            withMountains++;
    }
    printf("  islands: %d/%d fully solved with matching seams (%d cells each), %d local-WFC, "
            ~ "%d dropped, %d with mountains\n",
            cast(int)perfect, cast(int)seeds, cast(int)cells, cast(int)localWfc, cast(int)dropped,
            cast(int)withMountains);
    rep.check(perfect == seeds, "19-grid island: 100% solve rate, all seams match");
}

/// 16:9 rectangular maps, several sizes.
void runRectangles(const(AdjacencyRules)* rules, ref Report rep, uint seeds) @nogc nothrow @trusted {
    static immutable size_t[3] sizes = [2000, 8000, 20_000];
    auto solver = Solver(rules);
    size_t ok = 0, total = 0;
    foreach (target; sizes)
        foreach (seed; 1 .. seeds + 1) {
            total++;
            auto map = TileMap(MapRect.withAspect(target, 16, 9));
            auto rng = Random(seed * 7919);
            immutable st = generateMap(map, 8, solver, rng);
            immutable seams = checkSeams(rules, map);
            if (st.gridsFailed == 0 && seams.unsolved == 0 && seams.mismatches == 0)
                ok++;
        }
    printf("  16:9 maps: %d/%d fully solved with matching seams\n", cast(int)ok, cast(int)total);
    rep.check(ok == total, "16:9 maps: 100% solve rate, all seams match");
}

void run(const(AdjacencyRules)* rules, ref Report rep, uint islandSeeds, uint rectSeeds) @nogc nothrow {
    runIslands(rules, rep, islandSeeds);
    runRectangles(rules, rep, rectSeeds);
}
