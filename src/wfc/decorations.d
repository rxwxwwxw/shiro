// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from src/hexmap/Decorations.js and DecorationDefs.js (placement logic only).
// D port for the Shiro engine.
//
// Headless decoration placement. Every decision is a pure function of the solved tile map, the
// seed, and the cell's own coordinates (noise fields plus a coordinate hash), so decorations can
// be generated for any region in any order, and a map costs 2 bytes per cell.
module wfc.decorations;

import core.noise : SimplexNoise;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.road_rules : dirBit;
import wfc.routes : RoadNetwork;
import wfc.rules;
import wfc.tile_data;
import wfc.tile_map;

import core.stdc.stdlib : calloc, free;

enum DecoKind : ubyte {
    none,
    tree,
    building,
    windmill,
    bridge,
    mountain,
    /// Creep spawn point (a road endpoint).
    source,
    /// Creep goal (a road endpoint).
    sink,
    /// Rock wall beside a road on walkable non-flat ground.
    rock
}

/// Decorations ground creeps cannot walk through.
bool blocksGround(DecoKind k) @nogc nothrow pure @safe {
    return k == DecoKind.tree || k == DecoKind.building || k == DecoKind.windmill
        || k == DecoKind.mountain || k == DecoKind.rock;
}

/// One decoration slot per cell. Packs into 16 bits: kind(4) variant(4) facing(3) extra(3).
struct Decoration {
    DecoKind kind;
    /// tree: 0 = type A, 1 = type B. building: index into `buildingDefs`. bridge: 0/1.
    /// mountain: 0..2.
    ubyte variant;
    /// Direction the decoration faces (a HexDir) for buildings, windmills and bridges.
    HexDir facing;
    /// tree: density tier 0..3 (single, small, medium, large). building: 1 = has tower top.
    ubyte extra;

    ushort pack() const @nogc nothrow pure @safe {
        return cast(ushort)(kind | (variant << 4) | (facing << 8) | (extra << 11));
    }

    static Decoration unpack(ushort v) @nogc nothrow pure @safe {
        return Decoration(cast(DecoKind)(v & 15), (v >> 4) & 15, cast(HexDir)((v >> 8) & 7), (v >> 11) & 7);
    }
}

struct WeightedDef {
    string name;
    ubyte weight;
}

immutable WeightedDef[8] buildingDefs = [
    WeightedDef("building_home_A_yellow", 15), WeightedDef("building_home_B_yellow", 6),
    WeightedDef("building_church_yellow", 2), WeightedDef("building_tower_A_yellow", 2),
    WeightedDef("building_townhall_yellow", 1), WeightedDef("building_well_yellow", 3),
    WeightedDef("building_market_yellow", 2), WeightedDef("building_blacksmith_yellow", 1)
];

immutable string[3] mountainNames = ["mountain_A_grass", "mountain_B_grass", "mountain_C_grass"];
immutable string[2] bridgeNames = ["building_bridge_A", "building_bridge_B"];
enum ubyte towerVariant = 3;

struct DecorationParams {
    uint seed = 1;
    float treeFrequency = 0.05f;
    float treeThreshold = 0.55f;
    float buildingFrequency = 0.02f;
    float buildingThreshold = 0.74f;
    /// Octaves of simplex noise sampled for the clustering fields.
    int octaves = 2;
    /// One in N eligible coast grass cells gets a windmill.
    uint windmillOneIn = 20;
    float towerTopChance = 0.5f;
}

private uint hash3(uint a, uint b, uint c) @nogc nothrow pure @safe {
    uint x = a * 0x9E3779B1u ^ b * 0x85EBCA6Bu ^ c * 0xC2B2AE35u;
    x ^= x >> 15;
    x *= 0x2C1B3C6Du;
    x ^= x >> 12;
    x *= 0x297A2D39u;
    x ^= x >> 15;
    return x;
}

private double hash01(uint h) @nogc nothrow pure @safe {
    return h / 4294967296.0;
}

/// World position of a cell with the reference implementation's unit layout (hex width 2).
private void worldPos(const CubeCoord c, out float x, out float z) @nogc nothrow pure @safe {
    immutable o = cubeToOffset(c);
    x = o.col * 2.0f + (o.row & 1);
    z = o.row * 1.7320508f;
}

// Unit vectors of the six pointy-top directions in (x, z) world space.
private immutable float[2][6] dirVec = [
    [0.5f, -0.8660254f], [1.0f, 0.0f], [0.5f, 0.8660254f], [-0.5f, 0.8660254f], [-1.0f, 0.0f],
    [-0.5f, -0.8660254f]
];

struct Decorator {
    private const(AdjacencyRules)* rules;
    DecorationParams params;
    private SimplexNoise noiseA, noiseB, noiseC;
    private bool[numTiles] waterish;
    private ubyte roadEndTile, crossingA, crossingB;
    private uint totalBuildingWeight;

    this(const(AdjacencyRules)* rules, DecorationParams params = DecorationParams.init) @nogc nothrow pure @safe {
        this.rules = rules;
        this.params = params;
        noiseA = SimplexNoise(params.seed * 3 + 1);
        noiseB = SimplexNoise(params.seed * 3 + 2);
        noiseC = SimplexNoise(params.seed * 3 + 3);
        foreach (i, ref t; tileList)
            waterish[i] = t.name == "WATER" || (t.name.length > 6 && t.name[0 .. 6] == "COAST_");
        roadEndTile = cast(ubyte)tileIdByName("ROAD_END");
        crossingA = cast(ubyte)tileIdByName("RIVER_CROSSING_A");
        crossingB = cast(ubyte)tileIdByName("RIVER_CROSSING_B");
        foreach (ref b; buildingDefs)
            totalBuildingWeight += b.weight;
    }

    private float field(ref const SimplexNoise n, float freq, float x, float z) const @nogc nothrow pure @safe {
        return (n.fbm(x * freq, z * freq, params.octaves) + 1.0f) * 0.5f;
    }

    private ubyte pickBuilding(uint h) const @nogc nothrow pure @safe {
        uint r = h % totalBuildingWeight;
        foreach (i, ref b; buildingDefs) {
            if (r < b.weight)
                return cast(ubyte)i;
            r -= b.weight;
        }
        return 0;
    }

    /// Exit direction of a dead-end road tile state (exactly one road edge), or false.
    private bool deadEndExit(size_t stateId, out HexDir exitDir) const @nogc nothrow pure @safe {
        int roads = 0;
        foreach (d; 0 .. numHexDirs)
            if (rules.stateEdges[stateId][d].type == EdgeType.road) {
                roads++;
                exitDir = cast(HexDir)d;
            }
        return roads == 1;
    }

    /// Decoration for one cell of the map (kind `none` for undecorated or unsolved cells).
    Decoration decorate(ref const TileMap map, const CubeCoord c) const @nogc nothrow @trusted {
        immutable id = map.get(c);
        if (id < 0)
            return Decoration.init;
        immutable state = rules.states[id];
        immutable h = hash3(cast(uint)c.q, cast(uint)c.r, params.seed);

        // Mountains mask dropped seams and take priority over everything.
        if (map.isMountain(c))
            return Decoration(DecoKind.mountain, cast(ubyte)((h >> 8) % 3), cast(HexDir)(h % 6), 0);

        if (state.tile == crossingA || state.tile == crossingB) {
            // Bridge runs along the crossing's road axis: face the first road edge.
            HexDir face = HexDir.NE;
            foreach (d; 0 .. numHexDirs)
                if (rules.stateEdges[id][d].type == EdgeType.road) {
                    face = cast(HexDir)d;
                    break;
                }
            return Decoration(DecoKind.bridge, state.tile == crossingA ? 0 : 1, face, 0);
        }

        HexDir exitDir;
        if (state.tile == roadEndTile && deadEndExit(id, exitDir)) {
            immutable v = pickBuilding(h >> 3);
            immutable top = v == towerVariant && hash01(h * 2654435761u) < params.towerTopChance;
            return Decoration(DecoKind.building, v, exitDir, top ? 1 : 0);
        }

        if (state.tile != 0) // only flat grass is decorated further
            return Decoration.init;

        // Coast windmill, facing the water.
        if (state.level == 0 && (h % params.windmillOneIn) == 0) {
            float vx = 0, vz = 0;
            bool water = false;
            foreach (d; 0 .. numHexDirs) {
                immutable nid = map.get(c.neighbor(cast(HexDir)d));
                if (nid >= 0 && waterish[rules.states[nid].tile]) {
                    vx += dirVec[d][0];
                    vz += dirVec[d][1];
                    water = true;
                }
            }
            if (water) {
                int best = 0;
                float bestDot = -1e9f;
                foreach (d; 0 .. numHexDirs) {
                    immutable dot = vx * dirVec[d][0] + vz * dirVec[d][1];
                    if (dot > bestDot) {
                        bestDot = dot;
                        best = cast(int)d;
                    }
                }
                return Decoration(DecoKind.windmill, 0, cast(HexDir)best, 0);
            }
        }

        float x, z;
        worldPos(c, x, z);

        // Village buildings where the building field is high.
        if (field(noiseC, params.buildingFrequency, x, z) >= params.buildingThreshold) {
            immutable v = pickBuilding(h >> 3);
            immutable top = v == towerVariant && hash01(h * 2654435761u) < params.towerTopChance;
            return Decoration(DecoKind.building, v, cast(HexDir)((h >> 20) % 6), top ? 1 : 0);
        }

        // Forests where either tree field is above the threshold; the higher field wins.
        immutable a = field(noiseA, params.treeFrequency, x, z);
        immutable b = field(noiseB, params.treeFrequency, x, z);
        immutable t = params.treeThreshold;
        if (a < t && b < t)
            return Decoration.init;
        immutable aWins = a >= b;
        immutable value = aWins ? a : b;
        immutable norm = (value - t) / (1.0f - t);
        int tier = cast(int)(norm * 4);
        if (tier > 3)
            tier = 3;
        return Decoration(DecoKind.tree, aWins ? 0 : 1, HexDir.NE, cast(ubyte)tier);
    }
}

/// Flat per-cell decoration storage (2 bytes per cell).
struct DecorationMap {
    MapRect rect;
    private ushort* data;

    @disable this(this);

    this(MapRect rect) @nogc nothrow @trusted {
        this.rect = rect;
        data = cast(ushort*)calloc(rect.cellCount, ushort.sizeof);
        assert(data !is null, "decoration map allocation failed");
    }

    ~this() @nogc nothrow @trusted {
        free(data);
    }

    size_t bytes() const @nogc nothrow pure @safe {
        return rect.cellCount * ushort.sizeof;
    }

    Decoration get(const CubeCoord c) const @nogc nothrow @trusted {
        if (!rect.contains(c))
            return Decoration.init;
        immutable o = cubeToOffset(c);
        return Decoration.unpack(data[cast(size_t)o.row * rect.cols + o.col]);
    }

    void set(const CubeCoord c, const Decoration d) @nogc nothrow @trusted {
        assert(rect.contains(c));
        immutable o = cubeToOffset(c);
        data[cast(size_t)o.row * rect.cols + o.col] = d.pack;
    }

    /// Fills the whole map from the tile map.
    void decorateAll(ref const TileMap tiles, ref const Decorator decorator) @nogc nothrow @trusted {
        foreach (row; 0 .. rect.rows)
            foreach (col; 0 .. rect.cols) {
                immutable c = offsetToCube(col, row);
                data[cast(size_t)row * rect.cols + col] = decorator.decorate(tiles, c).pack;
            }
    }

    size_t count(DecoKind kind) const @nogc nothrow @trusted {
        size_t n = 0;
        foreach (i; 0 .. rect.cellCount)
            if ((data[i] & 15) == kind)
                n++;
        return n;
    }
}

/// Marks road endpoints and walls the roads in: every ground-walkable cell within `wallDepth` of
/// a road that is not itself a road becomes dense forest (flat grass) or rock (slopes), so ground
/// creeps can only travel along the roads. Cells that already block (water, cliffs, trees,
/// buildings) are kept as they are.
void applyCorridors(ref DecorationMap decos, ref const TileMap tiles, ref const RoadNetwork net,
        const(AdjacencyRules)* rules, int wallDepth, uint seed) @nogc nothrow @trusted {
    immutable rect = tiles.rect;
    if (!net.allocated)
        return;
    if (wallDepth > 4)
        wallDepth = 4;
    CubeCoord[cellsInRadius(4)] ball = void;
    foreach (i; 0 .. rect.cellCount) {
        immutable c = rect.cellAt(i);
        if (!net.onNetwork(c))
            continue;
        if (net.isSource(c) || net.isSink(c)) {
            HexDir face = HexDir.NE;
            immutable dirs = net.roadDirs(c);
            foreach (d; 0 .. numHexDirs)
                if (dirs & dirBit(cast(HexDir)d)) {
                    face = cast(HexDir)d;
                    break;
                }
            if (!tiles.isMountain(c))
                decos.set(c, Decoration(net.isSource(c) ? DecoKind.source : DecoKind.sink, 0, face, 0));
        }
        if (wallDepth <= 0)
            continue;
        immutable n = cubeCoordsInRadius(c, wallDepth, ball[]);
        foreach (k; 0 .. n) {
            immutable w = ball[k];
            if (!rect.contains(w) || net.onNetwork(w))
                continue;
            immutable id = tiles.get(w);
            if (id < 0)
                continue;
            immutable st = rules.states[id];
            if (!groundWalkable(st.tile) || blocksGround(decos.get(w).kind))
                continue;
            immutable h = hash3(cast(uint)w.q, cast(uint)w.r, seed ^ 0x51ED27u);
            if (st.tile == 0)
                decos.set(w, Decoration(DecoKind.tree, cast(ubyte)(h & 1), HexDir.NE, 3));
            else
                decos.set(w, Decoration(DecoKind.rock, cast(ubyte)((h >> 4) % 3), cast(HexDir)(h % 6), 0));
        }
    }
}

// ---- tests -----------------------------------------------------------------------------------

version (unittest) {
    import core.random : Random;
    import wfc.map_generator;
    import wfc.solver;

    private __gshared AdjacencyRules testRules;
    private __gshared bool testRulesReady;

    private const(AdjacencyRules)* rulesForTest() @nogc nothrow @trusted {
        if (!testRulesReady) {
            AdjacencyRules.build(testRules);
            testRulesReady = true;
        }
        return &testRules;
    }
}

@nogc nothrow pure @safe unittest {
    // Packing round trip over every combination.
    foreach (k; 0 .. 6)
        foreach (v; 0 .. 8)
            foreach (f; 0 .. 6)
                foreach (e; 0 .. 4) {
                    immutable d = Decoration(cast(DecoKind)k, cast(ubyte)v, cast(HexDir)f, cast(ubyte)e);
                    assert(Decoration.unpack(d.pack) == d);
                }
}

unittest {
    // Hand-built map: each rule fires on the right tile type with the right orientation.
    const rules = rulesForTest();
    auto map = TileMap(MapRect(12, 8));
    auto dec = Decorator(rules, DecorationParams(7));
    // Fill with water, then place specific tiles.
    foreach (row; 0 .. 8)
        foreach (col; 0 .. 12)
            map.set(offsetToCube(col, row), rules.stateId(1, 0, 0));

    immutable roadEnd = tileIdByName("ROAD_END");
    immutable endState = rules.stateId(roadEnd, 2, 0);
    immutable endCell = offsetToCube(3, 3);
    map.set(endCell, endState);
    immutable d1 = dec.decorate(map, endCell);
    assert(d1.kind == DecoKind.building);
    assert(rules.stateEdges[endState][d1.facing].type == EdgeType.road);

    immutable cross = tileIdByName("RIVER_CROSSING_B");
    immutable crossCell = offsetToCube(6, 4);
    map.set(crossCell, rules.stateId(cross, 1, 1));
    immutable d2 = dec.decorate(map, crossCell);
    assert(d2.kind == DecoKind.bridge && d2.variant == 1);
    assert(rules.stateEdges[rules.stateId(cross, 1, 1)][d2.facing].type == EdgeType.road);

    immutable mCell = offsetToCube(9, 2);
    map.set(mCell, rules.stateId(0, 0, 0));
    map.setMountain(mCell);
    assert(dec.decorate(map, mCell).kind == DecoKind.mountain);
    // Mountains also override a bridge tile.
    map.setMountain(crossCell);
    assert(dec.decorate(map, crossCell).kind == DecoKind.mountain);

    // Water and unsolved cells are never decorated.
    assert(dec.decorate(map, offsetToCube(0, 0)).kind == DecoKind.none);
    assert(dec.decorate(map, offsetToCube(-5, 0)).kind == DecoKind.none);
}

unittest {
    // Generated 16:9 map: placement obeys tile rules, is deterministic, and has plausible density.
    const rules = rulesForTest();
    auto solver = Solver(rules);
    auto tiles = TileMap(MapRect.withAspect(8000, 16, 9));
    auto rng = Random(2026);
    assert(generateMap(tiles, 6, solver, rng).gridsFailed == 0);

    auto dec = Decorator(rules, DecorationParams(42));
    auto decos = DecorationMap(tiles.rect);
    decos.decorateAll(tiles, dec);
    auto decos2 = DecorationMap(tiles.rect);
    auto dec2 = Decorator(rules, DecorationParams(42));
    decos2.decorateAll(tiles, dec2);

    size_t grass, trees, windmills, buildings;
    foreach (row; 0 .. tiles.rect.rows)
        foreach (col; 0 .. tiles.rect.cols) {
            immutable c = offsetToCube(col, row);
            immutable d = decos.get(c);
            assert(d == decos2.get(c));
            immutable id = tiles.get(c);
            immutable st = rules.states[id];
            if (st.tile == 0 && !tiles.isMountain(c))
                grass++;
            final switch (d.kind) {
            case DecoKind.none:
                break;
            case DecoKind.tree:
                trees++;
                assert(st.tile == 0 && !tiles.isMountain(c) && d.extra <= 3);
                break;
            case DecoKind.building:
                buildings++;
                break;
            case DecoKind.windmill:
                windmills++;
                assert(st.tile == 0 && st.level == 0);
                // at least one water/coast neighbor
                bool nearWater = false;
                foreach (nd; 0 .. numHexDirs) {
                    immutable nid = tiles.get(c.neighbor(cast(HexDir)nd));
                    if (nid >= 0) {
                        immutable nn = tileList[rules.states[nid].tile].name;
                        if (nn == "WATER" || (nn.length > 6 && nn[0 .. 6] == "COAST_"))
                            nearWater = true;
                    }
                }
                assert(nearWater);
                break;
            case DecoKind.bridge:
                assert(st.tile == tileIdByName("RIVER_CROSSING_A")
                        || st.tile == tileIdByName("RIVER_CROSSING_B"));
                break;
            case DecoKind.mountain:
                assert(tiles.isMountain(c));
                break;
            case DecoKind.source:
            case DecoKind.sink:
            case DecoKind.rock:
                assert(false,
                        "corridor decorations need applyCorridors");
            }
        }
    assert(grass > 0);
    // Forests cover a meaningful but not overwhelming share of grass.
    assert(trees * 100 / grass >= 3 && trees * 100 / grass <= 70);
    assert(buildings > 0);
    assert(decos.count(DecoKind.mountain) == tiles.countMountains);
    // A different seed produces a different layout.
    auto decos3 = DecorationMap(tiles.rect);
    auto dec3 = Decorator(rules, DecorationParams(43));
    decos3.decorateAll(tiles, dec3);
    bool differs = false;
    foreach (row; 0 .. tiles.rect.rows)
        foreach (col; 0 .. tiles.rect.cols)
            if (decos.get(offsetToCube(col, row)) != decos3.get(offsetToCube(col, row)))
                differs = true;
    assert(differs);
}
