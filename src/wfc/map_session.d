// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// One-stop owner of everything a map generation needs (rules, solver, tile + decoration maps),
// so front ends (the SDL viewer, headless tools) never juggle solver internals. Headless Model.
module wfc.map_session;

import core.result;
import core.lifetime : emplace;
import core.random : Random;
import core.stdc.stdlib : malloc, free;
import core.time : MonoTime;
import wfc.decorations;
import wfc.grid_connector;
import wfc.hex;
import wfc.map_generator;
import wfc.rules;
import wfc.solver;
import wfc.tile_map;

enum Layout : ubyte {
    /// A cols x rows rectangle swept grid by grid.
    rect,
    /// A hexagonal cluster of grids (two rings = the 19-grid island of the reference).
    island
}

/// Upper bound on map cells, keeps a regeneration under ~1 s and a few MB on potato hardware.
enum size_t maxSessionCells = 250_000;
enum int minGridRadius = 1;
enum int maxGridRadius = 16;
enum int maxIslandRings = 4;

struct GenParams {
    Layout layout = Layout.rect;
    int cols = 96;
    int rows = 54;
    /// Cell radius of each WFC grid.
    int radius = 8;
    /// Island layout only: rings of grids around the center grid.
    int rings = 2;
    uint seed = 1;
    GenOptions gen;
    DecorationParams deco;
}

struct MapSession {
    private AdjacencyRules* rulesBuf;
    private Solver solver;
    private TileMap tileMap;
    private DecorationMap decoMap;
    private GenParams lastParams;
    private GridCoord islandCenter;
    GenStats stats;
    /// Wall-clock time of the last regeneration, in milliseconds.
    double genMillis = 0;

    @disable this(this);

    /// Builds the adjacency rules once; maps are created by `regenerate`.
    static Result!(MapSession*) create() @nogc nothrow @trusted {
        auto s = cast(MapSession*)malloc(MapSession.sizeof);
        auto r = cast(AdjacencyRules*)malloc(AdjacencyRules.sizeof);
        if (s is null || r is null) {
            free(s);
            free(r);
            return Result!(MapSession*).err(EngineError.InitializationFailed);
        }
        AdjacencyRules.build(*r);
        emplace(s);
        s.rulesBuf = r;
        s.solver = Solver(r);
        return Result!(MapSession*).ok(s);
    }

    /// Frees a session made by `create`.
    static void release(ref MapSession* s) @nogc nothrow @trusted {
        if (s is null)
            return;
        auto r = s.rulesBuf;
        object.destroy!false(*s);
        free(r);
        free(s);
        s = null;
    }

    ref const(TileMap) tiles() const return @nogc nothrow pure @safe {
        return tileMap;
    }

    ref const(DecorationMap) decorations() const return @nogc nothrow pure @safe {
        return decoMap;
    }

    const(AdjacencyRules)* rules() const @nogc nothrow pure @safe {
        return rulesBuf;
    }

    ref const(GenParams) params() const return @nogc nothrow pure @safe {
        return lastParams;
    }

    /// True if the cell is part of the generated area (island layouts leave the rectangle's
    /// corners outside the cluster; those cells stay unsolved by design, not by failure).
    bool inMap(const CubeCoord c) const @nogc nothrow pure @safe {
        if (!tileMap.rect.contains(c))
            return false;
        if (lastParams.layout == Layout.rect)
            return true;
        immutable a = toAxial(gridOfCell(c, lastParams.radius));
        immutable b = toAxial(islandCenter);
        return cubeDistance(CubeCoord.fromAxial(a.gq, a.gr), CubeCoord.fromAxial(b.gq, b.gr)) <= lastParams.rings;
    }

    /// Validates `p`, then generates a fresh tile map and decorations for it.
    Result!GenStats regenerate(const GenParams p) @nogc nothrow @trusted {
        if (p.radius < minGridRadius || p.radius > maxGridRadius)
            return Result!GenStats.err(EngineError.InvalidHexCoordinates);
        MapRect rect;
        GridCoord[64] grids = void;
        size_t ng = 0;
        if (p.layout == Layout.island) {
            if (p.rings < 0 || p.rings > maxIslandRings)
                return Result!GenStats.err(EngineError.InvalidHexCoordinates);
            fitCluster(p.rings, p.radius, islandCenter, rect);
            ng = clusterGrids(islandCenter, p.rings, grids[]);
        } else {
            if (p.cols < 1 || p.rows < 1)
                return Result!GenStats.err(EngineError.InvalidHexCoordinates);
            rect = MapRect(p.cols, p.rows);
        }
        if (rect.cellCount > maxSessionCells)
            return Result!GenStats.err(EngineError.BufferOverflow);

        immutable t0 = MonoTime.currTime;
        lastParams = p;
        tileMap = TileMap(rect);
        auto rng = Random(p.seed);
        if (p.layout == Layout.island)
            stats = generateGrids(tileMap, grids[0 .. ng], p.radius, solver, rng, p.gen);
        else
            stats = generateMap(tileMap, p.radius, solver, rng, p.gen);
        DecorationParams dp = p.deco;
        dp.seed = p.seed;
        auto decorator = Decorator(rulesBuf, dp);
        decoMap = DecorationMap(rect);
        decoMap.decorateAll(tileMap, decorator);
        genMillis = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
        return Result!GenStats.ok(stats);
    }
}

version (unittest) {
    private size_t countInMap(ref const MapSession s) @nogc nothrow @safe {
        size_t n = 0;
        foreach (row; 0 .. s.tiles.rect.rows)
            foreach (col; 0 .. s.tiles.rect.cols)
                if (s.inMap(offsetToCube(col, row)))
                    n++;
        return n;
    }
}

@nogc nothrow unittest {
    // Rectangular maps: fully solved, decorated, and the session can be resized in place.
    auto r = MapSession.create();
    assert(r.isOk);
    auto s = r.value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 40;
    p.rows = 24;
    p.radius = 4;
    p.seed = 3;
    immutable st = s.regenerate(p);
    assert(st.isOk && st.value.gridsFailed == 0);
    assert(s.tiles.countSolved == 40 * 24 && countInMap(*s) == 40 * 24);
    assert(s.decorations.rect.cols == 40 && s.genMillis >= 0);
    size_t decorated = 0;
    foreach (k; DecoKind.tree .. DecoKind.mountain + 1)
        decorated += s.decorations.count(cast(DecoKind)k);
    assert(decorated > 0);

    p.cols = 17;
    p.rows = 9;
    assert(s.regenerate(p).isOk);
    assert(s.tiles.rect.cols == 17 && s.tiles.rect.rows == 9 && s.tiles.countSolved == 17 * 9);
    assert(s.params.cols == 17);
}

@nogc nothrow unittest {
    // Island layout: every cluster cell is solved, cells outside the cluster are not in the map.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.layout = Layout.island;
    p.radius = 4;
    p.rings = 1;
    p.gen = GenOptions(0, false);
    immutable st = s.regenerate(p);
    assert(st.isOk && st.value.gridsFailed == 0);
    immutable expected = 7 * cellsInRadius(4);
    assert(countInMap(*s) == expected && s.tiles.countSolved == expected);
    assert(s.tiles.rect.cellCount > expected);
}

@nogc nothrow unittest {
    // Same params, same map.
    auto a = MapSession.create().value;
    auto b = MapSession.create().value;
    scope (exit) {
        MapSession.release(a);
        MapSession.release(b);
    }
    GenParams p;
    p.cols = 30;
    p.rows = 20;
    p.radius = 5;
    p.seed = 42;
    a.regenerate(p);
    b.regenerate(p);
    foreach (row; 0 .. 20)
        foreach (col; 0 .. 30) {
            immutable c = offsetToCube(col, row);
            assert(a.tiles.get(c) == b.tiles.get(c));
            assert(a.decorations.get(c) == b.decorations.get(c));
        }
}

@nogc nothrow unittest {
    // Invalid parameters are rejected without touching the current map.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 12;
    p.rows = 8;
    p.radius = 3;
    assert(s.regenerate(p).isOk);
    GenParams bad = p;
    bad.radius = 0;
    assert(s.regenerate(bad).error == EngineError.InvalidHexCoordinates);
    bad = p;
    bad.cols = 0;
    assert(s.regenerate(bad).error == EngineError.InvalidHexCoordinates);
    bad = p;
    bad.cols = 1000;
    bad.rows = 1000;
    assert(s.regenerate(bad).error == EngineError.BufferOverflow);
    bad = p;
    bad.layout = Layout.island;
    bad.rings = maxIslandRings + 1;
    assert(s.regenerate(bad).error == EngineError.InvalidHexCoordinates);
    assert(s.tiles.rect.cols == 12 && s.tiles.countSolved == 12 * 8);
}
