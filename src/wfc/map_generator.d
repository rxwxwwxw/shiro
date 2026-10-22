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
import wfc.rules;
import wfc.solver;
import wfc.tile_map;

struct GenStats {
    size_t gridsSolved;
    size_t gridsFailed;
    /// Failures caused by the boundary alone vs. by exhausting the backtrack budget.
    size_t neighborFailures;
    size_t searchFailures;
    size_t cellsUnsolved;
    size_t unfixedCells;
    size_t changedCells;
    size_t backtracks;
}

/// Solves one grid's cells against the map. Returns true on success and writes tiles (and any
/// changed unfixed neighbors) into the map.
bool solveGrid(ref Solver solver, ref TileMap map, GridCoord g, int radius, ref Random rng, ref GenStats stats) @nogc nothrow @trusted {
    CubeCoord[cellsInRadius(16)] cells = void;
    immutable n = gridCellsInRect(g, radius, map.rect, cells[]);
    if (n == 0)
        return true;

    // Boundary: already-solved neighbors outside this grid (soft, so they can be unfixed).
    FixedCell[maxFixedCells] fixed = void;
    size_t nf = 0;
    foreach (i; 0 .. n) {
        foreach (d; 0 .. numHexDirs) {
            immutable nc = cells[i].neighbor(cast(HexDir)d);
            if (cubeDistance(nc, gridCenter(g, radius)) <= radius)
                continue; // inside this grid
            immutable id = map.get(nc);
            if (id < 0)
                continue;
            bool dup = false;
            foreach (j; 0 .. nf)
                if (fixed[j].coord == nc) {
                    dup = true;
                    break;
                }
            if (dup)
                continue;
            if (nf >= maxFixedCells)
                return false;
            fixed[nf++] = FixedCell(nc, solver.rulesState(id), true);
        }
    }

    scope TileLookup lookup = (const CubeCoord c) => map.get(c);
    auto r = solver.solve(cells[0 .. n], fixed[0 .. nf], null, rng, lookup);
    stats.unfixedCells += solver.unfixedCells.length;
    if (!r.isOk) {
        if (r.error == SolveError.NeighborConflict)
            stats.neighborFailures++;
        else
            stats.searchFailures++;
        return false;
    }
    stats.backtracks += r.value.backtracks;

    PlacedTile[maxSolveCells] placed = void;
    immutable np = solver.extract(placed[]);
    foreach (i; 0 .. np)
        map.set(placed[i].coord, solver.stateIdOf(placed[i].state));
    FixedCell[maxFixedCells] changed = void;
    immutable nc = solver.changedCells(changed[]);
    foreach (i; 0 .. nc)
        map.set(changed[i].coord, solver.stateIdOf(changed[i].state));
    stats.changedCells += nc;
    return true;
}

/// Fills `map` by sweeping grids of the given radius row by row (odd-q order). Grids that cannot
/// be solved are left unsolved and counted; layered recovery for them is added in the recovery
/// phase.
GenStats generateMap(ref TileMap map, int radius, ref Solver solver, ref Random rng) @nogc nothrow @trusted {
    GenStats stats;
    immutable b = gridBoundsForRect(map.rect, radius);
    foreach (z; b.minZ .. b.maxZ + 1)
        foreach (x; b.minX .. b.maxX + 1) {
            CubeCoord[cellsInRadius(16)] tmp = void;
            immutable g = GridCoord(x, z);
            immutable n = gridCellsInRect(g, radius, map.rect, tmp[]);
            if (n == 0)
                continue;
            if (solveGrid(solver, map, g, radius, rng, stats))
                stats.gridsSolved++;
            else {
                stats.gridsFailed++;
                stats.cellsUnsolved += n;
            }
        }
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

    /// Every pair of adjacent solved cells must have matching edges.
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
                    if (b < 0)
                        continue;
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
    // 16:9 map, small grids: whatever is solved is globally consistent across grid seams.
    auto solver = Solver(rulesForTest());
    auto map = TileMap(MapRect.withAspect(1500, 16, 9));
    auto rng = Random(2024);
    immutable stats = generateMap(map, 4, solver, rng);
    assert(stats.gridsSolved > 0);
    assert(countMismatches(map) == 0);
    assert(map.countSolved + stats.cellsUnsolved == map.rect.cellCount);
}

unittest {
    // Same seed, same map.
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
        foreach (col; 0 .. rect.cols)
            assert(m1.get(offsetToCube(col, row)) == m2.get(offsetToCube(col, row)));
}
