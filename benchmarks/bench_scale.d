// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Scale exploration: generates 16:9 maps of increasing size and reports time, peak RSS and
// solve/unfix statistics (run under `/usr/bin/time -l` for peak RSS). Usage: bench_scale [radius] [cells...]
module benchmarks.bench_scale;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import core.random : Random;
import wfc.grid_connector;
import wfc.map_generator;
import wfc.rules;
import wfc.solver;
import wfc.tile_map;

__gshared AdjacencyRules rules;

int parseUint(const(char)[] s) @nogc nothrow pure @safe {
    int v = 0;
    foreach (ch; s)
        if (ch >= '0' && ch <= '9')
            v = v * 10 + (ch - '0');
    return v;
}

int main(string[] args) {
    int radius = 8;
    if (args.length > 1)
        radius = parseUint(args[1]);
    size_t[8] sizes = [10_000, 50_000, 200_000, 500_000, 1_000_000, 2_000_000, 0, 0];
    size_t nSizes = 6;
    if (args.length > 2) {
        nSizes = 0;
        foreach (a; args[2 .. $])
            if (nSizes < sizes.length)
                sizes[nSizes++] = cast(size_t)parseUint(a);
    }

    AdjacencyRules.build(rules);
    printf("radius %d, grid cells %d, solver arena %d KiB, rules %d KiB\n", radius,
            cast(int)cellsPerGrid(radius), cast(int)(Solver.storageBytes / 1024),
            cast(int)(AdjacencyRules.sizeof / 1024));
    printf("%10s %9s %8s %9s %7s %6s %7s %6s %8s %7s\n", "cells".ptr, "map".ptr, "ms".ptr,
            "us/cell".ptr, "grids".ptr, "failed".ptr, "local".ptr, "drop".ptr, "mountain".ptr, "mapKiB".ptr);
    foreach (target; sizes[0 .. nSizes]) {
        auto solver = Solver(&rules);
        auto map = TileMap(MapRect.withAspect(target, 16, 9));
        auto rng = Random(12345);
        immutable t0 = MonoTime.currTime;
        immutable st = generateMap(map, radius, solver, rng);
        immutable us = (MonoTime.currTime - t0).total!"usecs";
        printf("%10d %4dx%-4d %8d %9.2f %7d %6d %7d %6d %8d %7d\n", cast(int)map.rect.cellCount,
                map.rect.cols, map.rect.rows, cast(int)(us / 1000),
                cast(double)us / map.rect.cellCount, cast(int)st.gridsSolved,
                cast(int)st.gridsFailed, cast(int)st.recovery.localAttempts,
                cast(int)st.recovery.dropped, cast(int)map.countMountains, cast(int)(map.bytes / 1024));
    }
    return 0;
}
