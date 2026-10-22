// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from src/hexmap/HexMap.js (_runWfcWithRecovery). D port for the Shiro engine.
//
// Layered recovery for a grid whose solve fails:
//   Tier 1 (inside Solver.solve)  soft neighbor unfixing
//   Tier 2 local-WFC              re-solve a radius-2 region around the failure, then retry
//   Tier 3 drop / mountain        drop the nearest boundary constraint and flag it as a mountain
module wfc.recovery;

import core.random : Random;
import wfc.hex;
import wfc.rules;
import wfc.solver;
import wfc.tile_map;

enum int localRegionRadius = 2;
enum int maxLocalAttempts = 5;
/// Last-resort retries with no boundary constraints left.
enum int maxFreeRetries = 20;

struct RecoveryStats {
    size_t localAttempts;
    size_t localSuccesses;
    size_t dropped;
    size_t freeRetries;
    size_t backtracks;
    size_t unfixed;
    size_t changed;
}

/// Collects solved map cells adjacent to the hex ball (center, radius) as soft boundary cells.
size_t gatherFixed(ref const TileMap map, const CubeCoord[] cells, const CubeCoord center, int radius,
        ref Solver solver, FixedCell[] fixed) @nogc nothrow @trusted {
    size_t nf = 0;
    foreach (ref c; cells) {
        foreach (d; 0 .. numHexDirs) {
            immutable nc = c.neighbor(cast(HexDir)d);
            if (cubeDistance(nc, center) <= radius)
                continue;
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
            if (nf >= fixed.length)
                return nf;
            fixed[nf++] = FixedCell(nc, solver.rulesState(id), true);
        }
    }
    return nf;
}

/// Writes a successful solve (solved cells plus changed unfixed neighbors) into the map.
void commit(ref Solver solver, ref TileMap map, ref RecoveryStats stats) @nogc nothrow @trusted {
    PlacedTile[maxSolveCells] placed = void;
    immutable np = solver.extract(placed[]);
    foreach (i; 0 .. np)
        map.set(placed[i].coord, solver.stateIdOf(placed[i].state));
    FixedCell[maxFixedCells] changed = void;
    immutable nc = solver.changedCells(changed[]);
    foreach (i; 0 .. nc)
        map.set(changed[i].coord, solver.stateIdOf(changed[i].state));
    stats.unfixed += solver.unfixedCells.length;
    stats.changed += nc;
}

private struct Attempt {
    bool ok;
    SolveError error;
    Conflict conflict;
}

private Attempt attempt(ref Solver solver, ref TileMap map, const CubeCoord[] cells,
        const FixedCell[] fixed, const FixedCell[] initial, ref Random rng, ref RecoveryStats stats,
        CellConstraints cons) @nogc nothrow @trusted {
    scope TileLookup lookup = (const CubeCoord c) => map.get(c);
    auto r = solver.solve(cells, fixed, initial, rng, lookup, cons.mask);
    if (r.isOk) {
        stats.backtracks += r.value.backtracks;
        commit(solver, map, stats);
        return Attempt(true, SolveError.None, Conflict.init);
    }
    stats.unfixed += solver.unfixedCells.length;
    return Attempt(false, r.error, solver.lastConflict);
}

/// Mini-WFC on the radius-2 region around `center`: every mapped cell in the region is re-solved
/// against its (hard) outside neighbors. Returns true if the region was re-solved and written.
private bool localWfc(ref Solver local, ref TileMap map, const CubeCoord center, ref Random rng,
        ref RecoveryStats stats, CellConstraints cons) @nogc nothrow @trusted {
    CubeCoord[cellsInRadius(localRegionRadius)] ball = void;
    immutable nb = cubeCoordsInRadius(center, localRegionRadius, ball[]);
    CubeCoord[cellsInRadius(localRegionRadius)] region = void;
    size_t n = 0;
    foreach (i; 0 .. nb)
        if (map.get(ball[i]) >= 0)
            region[n++] = ball[i];
    if (n == 0)
        return false;

    FixedCell[maxFixedCells] fixed = void;
    size_t nf = gatherFixed(map, region[0 .. n], center, localRegionRadius, local, fixed[]);
    foreach (i; 0 .. nf)
        fixed[i].soft = false;

    auto r = local.solve(region[0 .. n], fixed[0 .. nf], null, rng, null, cons.mask);
    if (!r.isOk)
        return false;
    stats.backtracks += r.value.backtracks;
    PlacedTile[maxSolveCells] placed = void;
    immutable np = local.extract(placed[]);
    foreach (i; 0 .. np)
        map.set(placed[i].coord, local.stateIdOf(placed[i].state));
    return true;
}

private void removeFixed(FixedCell[] fixed, ref size_t nf, size_t idx) @nogc nothrow pure @safe {
    fixed[idx] = fixed[--nf];
}

/// Nearest fixed cell to `to` not in `skip`; protected cells rank behind every unprotected one.
private int nearestFixed(const FixedCell[] fixed, size_t nf, const CubeCoord to,
        const CubeCoord[] skip, CellConstraints cons) @nogc nothrow @trusted {
    int best = -1;
    int bestDist = int.max;
    foreach (i; 0 .. nf) {
        bool skipped = false;
        foreach (ref s; skip)
            if (s == fixed[i].coord)
                skipped = true;
        if (skipped)
            continue;
        int d = cubeDistance(fixed[i].coord, to);
        if (cons.protect !is null && cons.protect(fixed[i].coord))
            d += 1 << 20;
        if (d < bestDist) {
            bestDist = d;
            best = cast(int)i;
        }
    }
    return best;
}

/// Solves the grid `cells` (a hex ball around `center`, possibly clipped) against the map with
/// the full recovery pipeline and writes the result. Returns false only if every tier failed.
bool solveWithRecovery(ref Solver main, ref Solver local, ref TileMap map, const CubeCoord[] cells,
        const CubeCoord center, int radius, const FixedCell[] initial, ref Random rng,
        ref RecoveryStats stats, CellConstraints cons = CellConstraints.init) @nogc nothrow @trusted {
    FixedCell[maxFixedCells] fixed = void;
    size_t nf = gatherFixed(map, cells, center, radius, main, fixed[]);

    // Tier 1 (unfixing happens inside the solver).
    auto a = attempt(main, map, cells, fixed[0 .. nf], initial, rng, stats, cons);
    if (a.ok)
        return true;

    // Tier 2: local-WFC around the failure.
    CubeCoord[maxLocalAttempts] resolved = void;
    size_t nResolved = 0;
    foreach (tries; 0 .. maxLocalAttempts) {
        if (!a.conflict.valid)
            break;
        int ci = -1;
        CubeCoord lc;
        if (tries == 0 && a.error == SolveError.NeighborConflict && a.conflict.sourceIsFixed) {
            lc = a.conflict.source;
        } else {
            ci = nearestFixed(fixed[], nf, a.conflict.failed, resolved[0 .. nResolved], cons);
            if (ci < 0)
                break;
            lc = fixed[ci].coord;
        }
        resolved[nResolved++] = lc;
        stats.localAttempts++;
        if (!localWfc(local, map, lc, rng, stats, cons))
            continue;
        stats.localSuccesses++;

        // The map changed under the boundary; rebuild it and retry.
        nf = gatherFixed(map, cells, center, radius, main, fixed[]);
        a = attempt(main, map, cells, fixed[0 .. nf], initial, rng, stats, cons);
        if (a.ok)
            return true;
    }

    // Tier 3: drop boundary constraints, nearest to the failure first.
    CubeCoord[maxFixedCells] droppedCoords = void;
    size_t nDropped = 0;
    while (!a.ok && nf > 0) {
        immutable idx = a.conflict.valid ? nearestFixed(fixed[], nf, a.conflict.failed, null, cons) : 0;
        droppedCoords[nDropped++] = fixed[idx].coord;
        removeFixed(fixed[], nf, idx);
        stats.dropped++;
        a = attempt(main, map, cells, fixed[0 .. nf], initial, rng, stats, cons);
    }

    // Nothing left to drop: re-roll, then give up on the forced seeds.
    foreach (i; 0 .. maxFreeRetries) {
        if (a.ok)
            break;
        stats.freeRetries++;
        a = attempt(main, map, cells, fixed[0 .. nf], i < maxFreeRetries / 2 ? initial : null, rng, stats, cons);
    }
    if (!a.ok)
        return false;

    foreach (i; 0 .. nDropped)
        map.setMountain(droppedCoords[i]);
    return true;
}
