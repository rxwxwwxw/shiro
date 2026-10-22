// Movement layer for creeps: per-cell passability flags derived from the solved tiles, the
// decorations and the road network, plus the multi-sink BFS distance field that flow-field
// movement is built on, and validation that a map is playable.
module wfc.passability;

import core.stdc.stdlib : malloc, calloc, free;
import wfc.decorations;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.placement : EndpointKind;
import wfc.road_rules : RoadMasks;
import wfc.routes : RoadNetwork;
import wfc.rules;
import wfc.tile_data;
import wfc.tile_map;

enum NavFlag : ubyte {
    /// Ground creeps can stand here.
    ground = 1,
    /// Swimming creeps can stand here.
    water = 2,
    road = 4,
    source = 8,
    sink = 16
}

enum ushort unreachable = ushort.max;

struct NavMap {
    MapRect rect;
    private ubyte* flags;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(flags);
    }

    /// Builds the flags for every cell. Unsolved cells and mountains block everything.
    void build(ref const TileMap tiles, ref const DecorationMap decos, ref const RoadNetwork net,
            const(AdjacencyRules)* rules) @nogc nothrow @trusted {
        free(flags);
        rect = tiles.rect;
        flags = cast(ubyte*)calloc(rect.cellCount, 1);
        assert(flags !is null, "nav map allocation failed");
        foreach (i; 0 .. rect.cellCount) {
            immutable c = rect.cellAt(i);
            immutable id = tiles.get(c);
            if (id < 0 || tiles.isMountain(c))
                continue;
            immutable tile = rules.states[id].tile;
            ubyte f = 0;
            immutable deco = decos.get(c).kind;
            if (groundWalkable(tile) && !blocksGround(deco))
                f |= NavFlag.ground;
            if (swimmable(tile))
                f |= NavFlag.water;
            if (net.allocated) {
                if (net.roadDirs(c))
                    f |= NavFlag.road;
                if (net.isSource(c))
                    f |= NavFlag.source;
                if (net.isSink(c))
                    f |= NavFlag.sink;
            }
            flags[i] = f;
        }
    }

    ubyte get(const CubeCoord c) const @nogc nothrow @trusted {
        if (flags is null || !rect.contains(c))
            return 0;
        return flags[rect.index(c)];
    }

    bool ground(const CubeCoord c) const @nogc nothrow @safe {
        return (get(c) & NavFlag.ground) != 0;
    }

    /// Test hook: overrides one cell's flags.
    void setForTest(const CubeCoord c, ubyte f) @nogc nothrow @trusted {
        if (flags is null) {
            flags = cast(ubyte*)calloc(rect.cellCount, 1);
            assert(flags !is null);
        }
        flags[rect.index(c)] = f;
    }
}

/// Multi-source BFS over cells with all of `need` flags, from every cell with the `from` flag.
/// `dist` must hold rect.cellCount entries; unreachable cells get `unreachable`. Returns the
/// number of cells reached.
size_t navDistance(ref const NavMap nav, NavFlag from, ubyte need, ushort[] dist) @nogc nothrow @trusted {
    immutable rect = nav.rect;
    assert(dist.length >= rect.cellCount);
    dist[0 .. rect.cellCount] = unreachable;
    auto queue = cast(uint*)malloc(rect.cellCount * uint.sizeof);
    assert(queue !is null, "nav queue allocation failed");
    scope (exit)
        free(queue);
    size_t head = 0, tail = 0;
    foreach (i; 0 .. rect.cellCount) {
        immutable f = nav.flags[i];
        if ((f & from) && (f & need) == need) {
            dist[i] = 0;
            queue[tail++] = cast(uint)i;
        }
    }
    while (head < tail) {
        immutable i = queue[head++];
        immutable c = rect.cellAt(i);
        immutable nd = cast(ushort)(dist[i] + 1);
        foreach (d; 0 .. numHexDirs) {
            immutable nc = c.neighbor(cast(HexDir)d);
            if (!rect.contains(nc))
                continue;
            immutable j = rect.index(nc);
            if (dist[j] != unreachable || (nav.flags[j] & need) != need)
                continue;
            dist[j] = nd;
            queue[tail++] = cast(uint)j;
        }
    }
    return tail;
}

/// Ground distance (in steps) from every cell to the nearest sink: the basis of the ground creep
/// flow field (each creep steps to the neighbor with the smallest distance).
size_t groundDistanceToSinks(ref const NavMap nav, ushort[] dist) @nogc nothrow @trusted {
    return navDistance(nav, NavFlag.sink, NavFlag.ground, dist);
}

struct RouteReport {
    /// Sources with a ground path to some sink.
    int sourcesConnected;
    /// Sinks reachable on the ground from some source.
    int sinksReached;
    int sources, sinks;
    /// Planned road cells whose solved tile has different road exits (or none).
    size_t roadMismatches;
    /// Road cells covered by a mountain (a dropped WFC seam).
    size_t roadMountains;
    /// Ground cells reachable from a source that are not road: shortcuts around the roads.
    size_t leakCells;
    /// Ground cells reachable from any source (the creep-walkable area).
    size_t reachableCells;

    bool ok() const @nogc nothrow pure @safe {
        return sources > 0 && sourcesConnected == sources && sinksReached == sinks
            && roadMismatches == 0 && roadMountains == 0 && leakCells == 0;
    }
}

/// Checks that the generated map is playable: tiles match the planned roads, every source reaches
/// a sink and every sink is reached, and creeps cannot leave the roads.
RouteReport validateRoutes(ref const NavMap nav, ref const TileMap tiles, ref const RoadNetwork net,
        ref const RoadMasks masks) @nogc nothrow @trusted {
    RouteReport rep;
    immutable rect = nav.rect;
    rep.sources = net.endpoints.numSources;
    rep.sinks = net.endpoints.numSinks;
    foreach (i; 0 .. rect.cellCount) {
        immutable c = rect.cellAt(i);
        immutable planned = net.roadDirs(c);
        immutable id = tiles.get(c);
        immutable placed = id < 0 ? 0 : masks.stateRoadDirs[id];
        if (planned != placed)
            rep.roadMismatches++;
        if (planned && tiles.isMountain(c))
            rep.roadMountains++;
    }

    auto dist = cast(ushort*)malloc(rect.cellCount * ushort.sizeof);
    assert(dist !is null);
    scope (exit)
        free(dist);
    groundDistanceToSinks(nav, dist[0 .. rect.cellCount]);
    foreach (ref s; net.endpoints.sourceCells)
        if (dist[rect.index(s)] != unreachable)
            rep.sourcesConnected++;

    rep.reachableCells = navDistance(nav, NavFlag.source, NavFlag.ground, dist[0 .. rect.cellCount]);
    foreach (ref k; net.endpoints.sinkCells)
        if (dist[rect.index(k)] != unreachable)
            rep.sinksReached++;
    foreach (i; 0 .. rect.cellCount)
        if (dist[i] != unreachable && !(nav.flags[i] & NavFlag.road))
            rep.leakCells++;
    return rep;
}

@nogc nothrow unittest {
    // Hand-built strip: ground cells along a row, water in the middle blocks, a bridge passes.
    NavMap nav;
    nav.rect = MapRect(10, 3);
    foreach (col; 0 .. 10)
        nav.setForTest(offsetToCube(col, 1), NavFlag.ground);
    nav.setForTest(offsetToCube(9, 1), NavFlag.ground | NavFlag.sink);
    ushort[30] dist;
    assert(groundDistanceToSinks(nav, dist[]) == 10);
    assert(dist[nav.rect.index(offsetToCube(0, 1))] == 9);
    assert(dist[nav.rect.index(offsetToCube(9, 1))] == 0);
    // Water (forest, any non-ground cell) at col 5 cuts the strip.
    nav.setForTest(offsetToCube(5, 1), NavFlag.water);
    groundDistanceToSinks(nav, dist[]);
    assert(dist[nav.rect.index(offsetToCube(0, 1))] == unreachable);
    assert(dist[nav.rect.index(offsetToCube(6, 1))] == 3);
    // A bridge is ground again.
    nav.setForTest(offsetToCube(5, 1), NavFlag.ground | NavFlag.road);
    groundDistanceToSinks(nav, dist[]);
    assert(dist[nav.rect.index(offsetToCube(0, 1))] == 9);
    // Two sinks: distance is to the nearest.
    nav.setForTest(offsetToCube(0, 1), NavFlag.ground | NavFlag.sink);
    groundDistanceToSinks(nav, dist[]);
    assert(dist[nav.rect.index(offsetToCube(3, 1))] == 3 && dist[nav.rect.index(offsetToCube(7, 1))] == 2);
}

@nogc nothrow unittest {
    // Tile and decoration rules: grass walks, a tree blocks, water swims, a mountain blocks all.
    auto rules = cast(AdjacencyRules*)malloc(AdjacencyRules.sizeof);
    scope (exit)
        free(rules);
    AdjacencyRules.build(*rules);
    auto tiles = TileMap(MapRect(4, 1));
    tiles.set(offsetToCube(0, 0), rules.stateId(0, 0, 0)); // grass
    tiles.set(offsetToCube(1, 0), rules.stateId(0, 0, 0)); // grass + tree
    tiles.set(offsetToCube(2, 0), rules.stateId(1, 0, 0)); // water
    tiles.set(offsetToCube(3, 0), rules.stateId(0, 0, 0)); // grass + mountain
    tiles.setMountain(offsetToCube(3, 0));
    auto decos = DecorationMap(tiles.rect);
    decos.set(offsetToCube(1, 0), Decoration(DecoKind.tree, 0, HexDir.NE, 3));
    RoadNetwork net;
    NavMap nav;
    nav.build(tiles, decos, net, rules);
    assert(nav.get(offsetToCube(0, 0)) == NavFlag.ground);
    assert(nav.get(offsetToCube(1, 0)) == 0);
    assert(nav.get(offsetToCube(2, 0)) == NavFlag.water);
    assert(nav.get(offsetToCube(3, 0)) == 0);
}
