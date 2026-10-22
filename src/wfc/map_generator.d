// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from src/hexmap/HexMap.js (grid orchestration). D port for the Shiro engine.
//
// Sweeps the grid-of-grids over a rectangular map, solving one grid at a time against the already
// solved neighbors (soft boundary unfixing on conflict). Only one grid's solver state is live at a
// time, so working memory is constant and the map itself costs 2 bytes per cell.
module wfc.map_generator;

import core.random : Random;
import wfc.grid_connector;
import wfc.hex;
import wfc.recovery;
import wfc.rules;
import wfc.solver;
import wfc.tile_data;
import wfc.tile_map;

struct GenOptions {
    /// Water seeds are placed on the map perimeter every `oceanSpacing` cells (0 disables).
    int oceanSpacing = 6;
    /// Grass is seeded at the map center so the interior starts as land.
    bool centerGrass = true;
}

struct GenStats {
    size_t gridsSolved;
    size_t gridsFailed;
    size_t cellsUnsolved;
    RecoveryStats recovery;
}

private enum size_t maxSeedsPerGrid = 64;

/// Forced collapses for the cells of one grid: ocean along the map perimeter, grass at the center.
private size_t gridSeeds(const MapRect rect, const GenOptions opt, const CubeCoord[] cells,
        FixedCell[] out_, ref const AdjacencyRules rules) @nogc nothrow @trusted {
    immutable water = TileState(cast(ubyte)tileIdByName("WATER"), 0, 0);
    immutable grass = TileState(cast(ubyte)tileIdByName("GRASS"), 0, 0);
    size_t n = 0;
    foreach (ref c; cells) {
        immutable o = cubeToOffset(c);
        immutable onEdge = o.col == 0 || o.row == 0 || o.col == rect.cols - 1 || o.row == rect.rows - 1;
        immutable corner = (o.col == 0 || o.col == rect.cols - 1) && (o.row == 0 || o.row == rect.rows - 1);
        if (opt.oceanSpacing > 0 && onEdge && (corner || (o.col + o.row) % opt.oceanSpacing == 0) && n < out_.length)
            out_[n++] = FixedCell(c, water);
        else if (opt.centerGrass && o.col == rect.cols / 2 && o.row == rect.rows / 2 && n < out_.length)
            out_[n++] = FixedCell(c, grass);
    }
    return n;
}

private bool solveOneGrid(ref Solver solver, ref Solver local, ref TileMap map, GridCoord g, int radius,
        GenOptions opt, ref Random rng, ref GenStats stats) @nogc nothrow @trusted {
    CubeCoord[cellsInRadius(16)] cells = void;
    immutable n = gridCellsInRect(g, radius, map.rect, cells[]);
    if (n == 0)
        return true;
    FixedCell[maxSeedsPerGrid] seeds = void;
    immutable ns = gridSeeds(map.rect, opt, cells[0 .. n], seeds[], *solver.rulesPtr);
    if (solveWithRecovery(solver, local, map, cells[0 .. n], gridCenter(g, radius), radius,
            seeds[0 .. ns], rng, stats.recovery)) {
        stats.gridsSolved++;
        return true;
    }
    stats.gridsFailed++;
    stats.cellsUnsolved += n;
    return false;
}

/// Fills `map` by sweeping grids of the given radius row by row (odd-q order), solving each
/// against its already-solved neighbors with the 3-tier recovery pipeline.
GenStats generateMap(ref TileMap map, int radius, ref Solver solver, ref Random rng, GenOptions opt = GenOptions.init) @nogc nothrow @trusted {
    GenStats stats;
    auto local = Solver(solver.rulesPtr, SolverOptions(5, 500));
    immutable b = gridBoundsForRect(map.rect, radius);
    foreach (z; b.minZ .. b.maxZ + 1)
        foreach (x; b.minX .. b.maxX + 1)
            solveOneGrid(solver, local, map, GridCoord(x, z), radius, opt, rng, stats);
    return stats;
}

/// Solves an explicit list of grids in the given order (e.g. the 19-grid island).
GenStats generateGrids(ref TileMap map, const GridCoord[] grids, int radius, ref Solver solver,
        ref Random rng, GenOptions opt = GenOptions.init) @nogc nothrow @trusted {
    GenStats stats;
    auto local = Solver(solver.rulesPtr, SolverOptions(5, 500));
    foreach (g; grids)
        solveOneGrid(solver, local, map, g, radius, opt, rng, stats);
    return stats;
}

version (unittest) {
    private __gshared AdjacencyRules testRules;
    private __gshared bool testRulesReady;

    private const(AdjacencyRules)* rulesForTest() @nogc nothrow @trusted {
        if (!testRulesReady) {
            AdjacencyRules.build(testRules);
            testRulesReady = true;
        }
        return &testRules;
    }

    /// Every pair of adjacent solved cells must have matching edges, except across mountains.
    private size_t countMismatches(ref const TileMap map) @nogc nothrow @trusted {
        const rules = rulesForTest();
        size_t bad = 0;
        foreach (row; 0 .. map.rect.rows)
            foreach (col; 0 .. map.rect.cols) {
                immutable c = offsetToCube(col, row);
                immutable a = map.get(c);
                if (a < 0)
                    continue;
                foreach (d; 0 .. numHexDirs) {
                    immutable b = map.get(c.neighbor(cast(HexDir)d));
                    if (b < 0 || map.isMountain(c) || map.isMountain(c.neighbor(cast(HexDir)d)))
                        continue; // mountains deliberately mask a dropped seam
                    immutable ea = rules.stateEdges[a][d];
                    immutable eb = rules.stateEdges[b][opposite(cast(HexDir)d)];
                    if (!edgesCompatible(ea.type, ea.level, eb.type, eb.level))
                        bad++;
                }
            }
        return bad;
    }
}

unittest {
    // 16:9 maps with small grids: every grid is solved (100% with recovery) and the whole map is
    // consistent across grid seams except where a dropped seam was masked by a mountain.
    foreach (seed; 1 .. 9) {
        auto solver = Solver(rulesForTest());
        auto map = TileMap(MapRect.withAspect(1500, 16, 9));
        auto rng = Random(seed);
        immutable stats = generateMap(map, 4, solver, rng);
        assert(stats.gridsFailed == 0 && stats.cellsUnsolved == 0);
        assert(map.countSolved == map.rect.cellCount);
        assert(countMismatches(map) == 0);
        assert(map.countMountains <= stats.recovery.dropped);
    }
}

unittest {
    // Radius-8 grids on a wider map, including ocean seeds on the perimeter.
    auto solver = Solver(rulesForTest());
    auto map = TileMap(MapRect.withAspect(6000, 16, 9));
    auto rng = Random(77);
    immutable stats = generateMap(map, 8, solver, rng);
    assert(stats.gridsFailed == 0);
    assert(map.countSolved == map.rect.cellCount);
    assert(countMismatches(map) == 0);
    // The perimeter is seeded with water, so some perimeter cells are water tiles.
    size_t water = 0;
    foreach (col; 0 .. map.rect.cols) {
        immutable id = map.get(offsetToCube(col, 0));
        if (id >= 0 && rulesForTest().states[id].tile == tileIdByName("WATER"))
            water++;
    }
    assert(water > 0);
}

unittest {
    // Same seed, same map; recovery is deterministic too.
    MapRect rect = MapRect(36, 20);
    auto s1 = Solver(rulesForTest());
    auto s2 = Solver(rulesForTest());
    auto m1 = TileMap(rect);
    auto m2 = TileMap(rect);
    auto r1 = Random(5);
    auto r2 = Random(5);
    generateMap(m1, 4, s1, r1);
    generateMap(m2, 4, s2, r2);
    foreach (row; 0 .. rect.rows)
        foreach (col; 0 .. rect.cols) {
            assert(m1.get(offsetToCube(col, row)) == m2.get(offsetToCube(col, row)));
            assert(m1.isMountain(offsetToCube(col, row)) == m2.isMountain(offsetToCube(col, row)));
        }
}

unittest {
    // Options: no seeds still generates a valid map.
    auto solver = Solver(rulesForTest());
    auto map = TileMap(MapRect(40, 24));
    auto rng = Random(3);
    immutable stats = generateMap(map, 4, solver, rng, GenOptions(0, false));
    assert(stats.gridsFailed == 0 && countMismatches(map) == 0);
}
