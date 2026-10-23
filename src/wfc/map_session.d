// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// One-stop owner of everything a map generation needs (rules, solver, tile + decoration maps),
// so front ends (the SDL viewer, headless tools) never juggle solver internals. Headless Model.
module wfc.map_session;

import core.result;
import core.lifetime : emplace, move;
import core.random : Random;
import core.stdc.stdlib : malloc, free;
import core.time : MonoTime;
import wfc.decorations;
import wfc.grid_connector;
import wfc.hex;
import wfc.map_generator;
import wfc.passability;
import wfc.placement;
import wfc.reveal;
import wfc.road_rules;
import wfc.routes;
import wfc.rules;
import wfc.solver;
import wfc.tile_data : tileIdByName;
import wfc.tile_map;

enum Layout : ubyte {
    /// A cols x rows rectangle swept grid by grid.
    rect,
    /// A hexagonal cluster of grids (two rings = the 19-grid island of the reference).
    island
}

/// Upper bound on map cells (a 2M-cell map takes ~30 s to generate and a few MB for the model).
enum size_t maxSessionCells = 2_100_000;
enum int minGridRadius = 1;
enum int maxGridRadius = 16;
enum int maxIslandRings = 4;
/// Whole-map retries (with derived seeds) when a generated map fails route validation.
enum int maxRouteAttempts = 4;
/// Reveal maps: endpoint + road plans tried per attempt before one passes the stage checks.
enum int maxRevealPlans = 24;

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
    /// Sources, sinks and walled roads for tower defense play.
    RouteParams routes;
    /// Start on a small window of the map and uncover the rest in stages (rect layout only).
    RevealParams reveal;
}

struct MapSession {
    private AdjacencyRules* rulesBuf;
    private Solver solver;
    private TileMap tileMap;
    private DecorationMap decoMap;
    private GenParams lastParams;
    private GridCoord islandCenter;
    private RoadMasks roadMasks;
    private StateSet flankStates;
    private RoadNetwork network_;
    private NavMap navMap;
    private RevealPlan revealPlan;
    GenStats stats;
    /// Route validation of the last map (all zero when routes are disabled).
    RouteReport routeReport;
    /// Whole-map attempts the last regeneration needed (1 = first try).
    int routeAttempts;
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
        RoadMasks.build(s.roadMasks, r);
        // Flank cells with terrain walls: no road, no flat grass.
        s.flankStates = s.roadMasks.allowed(0);
        foreach (lvl; 0 .. 5) {
            immutable id = r.stateId(tileIdByName("GRASS"), 0, lvl);
            if (id >= 0)
                s.flankStates.clear(id);
        }
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

    /// Planned roads and endpoints of the last map (unallocated when routes are disabled).
    ref const(RoadNetwork) network() const return @nogc nothrow pure @safe {
        return network_;
    }

    /// Creep passability of the last map.
    ref const(NavMap) nav() const return @nogc nothrow pure @safe {
        return navMap;
    }

    ref const(RoadMasks) masks() const return @nogc nothrow pure @safe {
        return roadMasks;
    }

    /// Reveal stages of the last map (`enabled` false when the whole map is played at once).
    ref const(RevealPlan) reveal() const return @nogc nothrow pure @safe {
        return revealPlan;
    }

    /// True if every reveal stage of the last map is playable on the solved terrain.
    bool revealPlayable() const @nogc nothrow @trusted {
        if (!revealPlan.enabled)
            return true;
        immutable n = navMap.rect.cellCount;
        auto flags = cast(ubyte*)malloc(n), exits = cast(ubyte*)malloc(n);
        assert(flags && exits, "reveal check allocation failed");
        scope (exit) {
            free(flags);
            free(exits);
        }
        foreach (i; 0 .. n) {
            immutable c = navMap.rect.cellAt(i);
            flags[i] = navMap.get(c);
            exits[i] = network_.roadDirs(c);
        }
        return stagesPlayable(revealPlan, flags[0 .. n], exits[0 .. n], navBits, lastParams.reveal.minDefensePath);
    }

    // WFC constraints from the planned network (member delegates: no closure allocation).
    private const(StateSet)* maskFor(const CubeCoord c) @nogc nothrow @trusted {
        if (!network_.rect.contains(c))
            return null;
        immutable dirs = network_.roadDirs(c);
        if (dirs == 0 && lastParams.routes.flankTerrain && !network_.onNetwork(c)) {
            foreach (d; 0 .. numHexDirs)
                if (network_.onNetwork(c.neighbor(cast(HexDir)d))) {
                    immutable o = cubeToOffset(c);
                    if (valueNoise(o.col, o.row, 6, lastParams.seed ^ 0xF1A2u) >= 512)
                        return &flankStates;
                    break;
                }
        }
        return &roadMasks.allowed(dirs);
    }

    private bool protectFor(const CubeCoord c) @nogc nothrow @trusted {
        return network_.onNetwork(c);
    }

    private static bool inIsland(const CubeCoord c, ref const GenParams p, const GridCoord center) @nogc nothrow pure @safe {
        immutable a = toAxial(gridOfCell(c, p.radius));
        immutable b = toAxial(center);
        return cubeDistance(CubeCoord.fromAxial(a.gq, a.gr), CubeCoord.fromAxial(b.gq, b.gr)) <= p.rings;
    }

    /// True if the cell is part of the generated area (island layouts leave the rectangle's
    /// corners outside the cluster; those cells stay unsolved by design, not by failure).
    bool inMap(const CubeCoord c) const @nogc nothrow pure @safe {
        if (!tileMap.rect.contains(c))
            return false;
        if (lastParams.layout == Layout.rect)
            return true;
        return inIsland(c, lastParams, islandCenter);
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
        immutable routed = p.routes.enabled;
        immutable staged = routed && p.reveal.enabled && p.layout == Layout.rect;
        if (!staged)
            revealPlan = RevealPlan.init;
        EngineError planError = EngineError.None;
        bool generated = false;
        foreach (attempt; 0 .. routed ? maxRouteAttempts : 1) {
            immutable seed = p.seed + cast(uint)attempt * 0x9E3779B9u;
            auto rng = Random(seed);
            CellConstraints cons;
            if (routed) {
                // Plan before touching the current map, so a failed plan keeps it.
                immutable center = islandCenter;
                scope InMapLookup inMap = (const CubeCoord c) @nogc nothrow => p.layout == Layout.rect
                    || inIsland(c, p, center);
                auto field = BoundaryField(rect, inMap);
                RevealPlan plan;
                if (staged) {
                    auto pr = planReveal(rect, p.reveal, rng);
                    if (!pr.isOk)
                        return Result!GenStats.err(pr.error);
                    plan = pr.value;
                }
                auto net = RoadNetwork.init;
                bool planned = false;
                foreach (_; 0 .. staged ? maxRevealPlans : 1) {
                    auto ep = staged ? placeStagedEndpoints(field, plan, p.routes.place, p.reveal.minDefensePath, rng)
                        : placeEndpoints(field, p.routes.place, rng);
                    if (!ep.isOk) {
                        planError = ep.error;
                        continue;
                    }
                    net = RoadNetwork(rect);
                    auto pn = planNetwork(net, field, ep.value, p.routes, rng);
                    if (!pn.isOk) {
                        planError = pn.error;
                        continue;
                    }
                    // Cheap check on the planned roads alone before paying for WFC.
                    if (staged && !planPlayable(net, plan, p.reveal.minDefensePath)) {
                        planError = EngineError.RoutingFailed;
                        continue;
                    }
                    planned = true;
                    break;
                }
                if (!planned)
                    continue;
                network_ = move(net);
                revealPlan = plan;
                cons.mask = &maskFor;
                cons.protect = &protectFor;
            } else {
                network_ = RoadNetwork.init;
                revealPlan = RevealPlan.init;
            }
            lastParams = p;
            generated = true;
            routeAttempts = attempt + 1;
            tileMap = TileMap(rect);
            if (p.layout == Layout.island)
                stats = generateGrids(tileMap, grids[0 .. ng], p.radius, solver, rng, p.gen, cons);
            else
                stats = generateMap(tileMap, p.radius, solver, rng, p.gen, cons);
            DecorationParams dp = p.deco;
            dp.seed = p.seed;
            auto decorator = Decorator(rulesBuf, dp);
            decoMap = DecorationMap(rect);
            decoMap.decorateAll(tileMap, decorator);
            routeReport = RouteReport.init;
            if (routed)
                applyCorridors(decoMap, tileMap, network_, rulesBuf, p.routes.wallDepth, seed);
            navMap.build(tileMap, decoMap, network_, rulesBuf);
            if (!routed)
                break;
            routeReport = validateRoutes(navMap, tileMap, network_, roadMasks);
            if (routeReport.ok && revealPlayable())
                break;
        }
        if (!generated)
            return Result!GenStats.err(planError);
        genMillis = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
        return Result!GenStats.ok(stats);
    }
}

private enum FlagBits navBits = FlagBits(NavFlag.ground, NavFlag.source, NavFlag.sink);

/// Stage checks on a planned network, before any terrain exists: road cells walk.
private bool planPlayable(ref const RoadNetwork net, ref const RevealPlan plan, int minDefensePath) @nogc nothrow @trusted {
    immutable n = net.rect.cellCount;
    auto flags = cast(ubyte*)malloc(n), exits = cast(ubyte*)malloc(n);
    assert(flags && exits, "reveal check allocation failed");
    scope (exit) {
        free(flags);
        free(exits);
    }
    foreach (i; 0 .. n) {
        immutable c = net.rect.cellAt(i);
        exits[i] = net.roadDirs(c);
        ubyte f = net.onNetwork(c) ? NavFlag.ground : 0;
        if (net.isSource(c))
            f |= NavFlag.source;
        if (net.isSink(c))
            f |= NavFlag.sink;
        flags[i] = f;
    }
    return stagesPlayable(plan, flags[0 .. n], exits[0 .. n], navBits, minDefensePath);
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
    bad.cols = 2000;
    bad.rows = 2000;
    assert(s.regenerate(bad).error == EngineError.BufferOverflow);
    bad = p;
    bad.layout = Layout.island;
    bad.rings = maxIslandRings + 1;
    assert(s.regenerate(bad).error == EngineError.InvalidHexCoordinates);
    assert(s.tiles.rect.cols == 12 && s.tiles.countSolved == 12 * 8);
}

@nogc nothrow unittest {
    // Tower defense maps: every source reaches a sink, every sink is reached, tiles follow the
    // planned roads, the roads are walled in, and the result is deterministic.
    auto a = MapSession.create().value;
    auto b = MapSession.create().value;
    scope (exit) {
        MapSession.release(a);
        MapSession.release(b);
    }
    static immutable int[2][4] counts = [[1, 1], [4, 2], [2, 4], [6, 3]];
    foreach (cnt; counts)
        foreach (seed; 1 .. 4) {
            GenParams p;
            p.cols = 64;
            p.rows = 40;
            p.radius = 6;
            p.seed = seed;
            p.routes.place.sources = cnt[0];
            p.routes.place.sinks = cnt[1];
            assert(a.regenerate(p).isOk);
            immutable rep = a.routeReport;
            assert(rep.ok, "route validation failed");
            assert(rep.sourcesConnected == cnt[0] && rep.sinksReached == cnt[1]);
            assert(a.network.endpoints.numSources == cnt[0] && a.tiles.countSolved == 64 * 40);
            assert(a.decorations.count(DecoKind.source) == cnt[0]);
            assert(a.decorations.count(DecoKind.sink) == cnt[1]);
            assert(b.regenerate(p).isOk);
            foreach (i; 0 .. a.tiles.rect.cellCount) {
                immutable c = a.tiles.rect.cellAt(i);
                assert(a.tiles.get(c) == b.tiles.get(c) && a.decorations.get(c) == b.decorations.get(c));
            }
        }
}

@nogc nothrow unittest {
    // Island layout with routes, and routes disabled leaves no network.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.layout = Layout.island;
    p.radius = 6;
    p.rings = 2;
    p.routes.place.sources = 3;
    p.routes.place.sinks = 2;
    foreach (seed; 1 .. 4) {
        p.seed = seed;
        assert(s.regenerate(p).isOk);
        assert(s.routeReport.ok);
        foreach (i; 0 .. s.network.endpoints.count)
            assert(s.inMap(s.network.endpoints.at(i)));
    }
    p.routes.enabled = false;
    assert(s.regenerate(p).isOk);
    assert(!s.network.allocated && s.decorations.count(DecoKind.source) == 0);
}

@nogc nothrow unittest {
    // Reveal maps: every stage is playable on the solved terrain, window 0 holds one sink, the
    // plan is deterministic, and island layouts ignore the reveal.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 96;
    p.rows = 54;
    p.radius = 6;
    p.reveal.enabled = true;
    int playable = 0;
    foreach (seed; 1 .. 5) {
        p.seed = seed;
        assert(s.regenerate(p).isOk);
        assert(s.reveal.enabled && s.reveal.numStages == p.reveal.stages);
        if (!s.routeReport.ok || !s.revealPlayable)
            continue;
        playable++;
        int sinks0 = 0;
        foreach (i; 0 .. s.network.endpoints.numSinks)
            sinks0 += s.reveal.window(0).contains(s.network.endpoints.sinks[i]);
        assert(sinks0 == 1);
        foreach (i; 0 .. s.network.endpoints.numSources)
            assert(!s.reveal.window(0).contains(s.network.endpoints.sources[i]));
        const w = s.reveal.windows;
        assert(s.regenerate(p).isOk && s.reveal.windows == w);
    }
    assert(playable >= 3);
    p.layout = Layout.island;
    p.rings = 1;
    assert(s.regenerate(p).isOk && !s.reveal.enabled);
}
