// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Benchmark: single-grid solve latency (radius 8, 217 cells) and full 19-grid island generation,
// checked against the low-spec budget. Exit code 1 if a budget is exceeded.
//
// Budgets (release build, dual-core class CPU): single grid p95 <= 15 ms, island <= 400 ms
// (about 5x slack over an Apple-silicon laptop, which measures ~2 ms and ~60 ms).
module benchmarks.bench_wfc_solve;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import core.random : Random;
import wfc.grid_connector;
import wfc.hex;
import wfc.map_generator;
import wfc.rules;
import wfc.solver;
import wfc.tile_map;

__gshared AdjacencyRules rules;

enum double singleGridP95BudgetMs = 15.0;
enum double islandBudgetMs = 400.0;

private void sortDoubles(double[] a) @nogc nothrow pure @safe {
    foreach (i; 1 .. a.length) {
        immutable v = a[i];
        size_t j = i;
        while (j > 0 && a[j - 1] > v) {
            a[j] = a[j - 1];
            j--;
        }
        a[j] = v;
    }
}

int main() {
    AdjacencyRules.build(rules);
    bool ok = true;

    // ---- single grid ----
    {
        enum size_t runs = 200;
        static __gshared double[runs] ms;
        auto solver = Solver(&rules);
        CubeCoord[maxSolveCells] cells;
        immutable n = cubeCoordsInRadius(CubeCoord(0, 0, 0), 8, cells[]);
        size_t failed = 0;
        long backtracks = 0;
        foreach (i; 0 .. runs) {
            auto rng = Random(cast(uint)i + 1);
            immutable t0 = MonoTime.currTime;
            auto r = solver.solve(cells[0 .. n], null, null, rng);
            ms[i] = (MonoTime.currTime - t0).total!"nsecs" * 1e-6;
            if (!r.isOk)
                failed++;
            else
                backtracks += r.value.backtracks;
        }
        sortDoubles(ms[]);
        double sum = 0;
        foreach (v; ms)
            sum += v;
        immutable p95 = ms[runs * 95 / 100];
        printf("single grid (R=8, %d cells): n=%d failed=%d  mean %.2f ms  p50 %.2f  p95 %.2f  "
                ~ "max %.2f  (%.1f us/cell, %.1f backtracks/grid)\n",
                cast(int)n, cast(int)runs, cast(int)failed, sum / runs, ms[runs / 2], p95,
                ms[runs - 1], sum / runs * 1000 / n, cast(double)backtracks / runs);
        if (p95 > singleGridP95BudgetMs) {
            printf("  BUDGET EXCEEDED: p95 %.2f ms > %.1f ms\n", p95, singleGridP95BudgetMs);
            ok = false;
        }
    }

    // ---- 19-grid island ----
    {
        GridCoord center;
        MapRect rect;
        fitCluster(2, 8, center, rect);
        GridCoord[19] grids;
        immutable ng = clusterGrids(center, 2, grids[]);
        auto solver = Solver(&rules);
        enum size_t runs = 20;
        double worst = 0, total = 0;
        size_t failedGrids = 0;
        foreach (i; 0 .. runs) {
            auto map = TileMap(rect);
            auto rng = Random(cast(uint)i + 1);
            immutable t0 = MonoTime.currTime;
            immutable st = generateGrids(map, grids[0 .. ng], 8, solver, rng, GenOptions(0, false));
            immutable t = (MonoTime.currTime - t0).total!"nsecs" * 1e-6;
            total += t;
            if (t > worst)
                worst = t;
            failedGrids += st.gridsFailed;
        }
        printf("19-grid island (%d cells): n=%d  mean %.1f ms  worst %.1f ms  failed grids %d\n",
                cast(int)(19 * cellsInRadius(8)), cast(int)runs, total / runs, worst, cast(int)failedGrids);
        if (worst > islandBudgetMs) {
            printf("  BUDGET EXCEEDED: worst %.1f ms > %.1f ms\n", worst, islandBudgetMs);
            ok = false;
        }
    }

    printf(ok ? "bench_wfc_solve: within budget\n" : "bench_wfc_solve: OVER BUDGET\n");
    return ok ? 0 : 1;
}
