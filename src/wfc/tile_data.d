// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from src/hexmap/HexTileData.js. D port for the Shiro engine.
module wfc.tile_data;

public import wfc.hex : HexDir, numHexDirs;

/// Number of elevation levels.
enum int levelsCount = 5;

enum EdgeType : ubyte {
    grass,
    water,
    road,
    river,
    coast
}

enum size_t numEdgeTypes = 5;

/// One tile definition. `edges` are in HexDir order (NE, E, SE, SW, W, NW) at rotation 0.
struct TileDef {
    string name;
    EdgeType[6] edges;
    ushort weight;
    /// Bitmask over HexDir (bit i = HexDir i) of edges raised by `levelIncrement`.
    ubyte highEdgeMask;
    /// 0 for flat tiles; 1 or 2 for slopes.
    ubyte levelIncrement;
    bool preventChaining;

    bool isSlope() const @nogc nothrow pure @safe {
        return highEdgeMask != 0;
    }
}

private enum eG = EdgeType.grass;
private enum eW = EdgeType.water;
private enum eR = EdgeType.road;
private enum eV = EdgeType.river;
private enum eC = EdgeType.coast;

/// Array index is the tile's numeric ID. Order matches TILE_LIST in the JS reference.
immutable TileDef[] tileList = [
    TileDef("GRASS", [eG, eG, eG, eG, eG, eG], 500, 0, 0, false),
    TileDef("WATER", [eW, eW, eW, eW, eW, eW], 500, 0, 0, false),
    TileDef("ROAD_A", [eG, eR, eG, eG, eR, eG], 30, 0, 0, false),
    TileDef("ROAD_B", [eR, eG, eG, eG, eR, eG], 8, 0, 0, false),
    TileDef("ROAD_D", [eR, eG, eR, eG, eR, eG], 2, 0, 0, true),
    TileDef("ROAD_E", [eR, eR, eG, eG, eR, eG], 2, 0, 0, true),
    TileDef("ROAD_F", [eG, eR, eR, eG, eR, eG], 2, 0, 0, true),
    TileDef("ROAD_END", [eG, eG, eG, eG, eR, eG], 1, 0, 0, true),
    TileDef("RIVER_A", [eG, eV, eG, eG, eV, eG], 20, 0, 0, false),
    TileDef("RIVER_A_CURVY", [eG, eV, eG, eG, eV, eG], 20, 0, 0, false),
    TileDef("RIVER_B", [eV, eG, eG, eG, eV, eG], 30, 0, 0, false),
    TileDef("RIVER_D", [eV, eG, eV, eG, eV, eG], 4, 0, 0, true),
    TileDef("RIVER_E", [eV, eV, eG, eG, eV, eG], 4, 0, 0, true),
    TileDef("RIVER_F", [eG, eV, eV, eG, eV, eG], 4, 0, 0, true),
    TileDef("RIVER_END", [eG, eG, eG, eG, eV, eG], 4, 0, 0, true),
    TileDef("COAST_A", [eG, eC, eW, eC, eG, eG], 20, 0, 0, false),
    TileDef("COAST_B", [eG, eC, eW, eW, eC, eG], 15, 0, 0, false),
    TileDef("COAST_C", [eC, eW, eW, eW, eC, eG], 15, 0, 0, false),
    TileDef("COAST_D", [eW, eW, eW, eW, eC, eC], 15, 0, 0, true),
    TileDef("COAST_E", [eG, eG, eC, eC, eG, eG], 10, 0, 0, true),
    TileDef("COAST_SLOPE_A_LOW", [eG, eG, eG, eC, eW, eC], 1,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 1, false),
    TileDef("COAST_SLOPE_A_HIGH", [eG, eG, eG, eC, eW, eC], 1,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 2, false),
    TileDef("RIVER_A_SLOPE_LOW", [eG, eV, eG, eG, eV, eG], 1,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 1, false),
    TileDef("RIVER_INTO_COAST", [eC, eW, eW, eW, eC, eV], 3, 0, 0, true),
    TileDef("RIVER_CROSSING_A", [eG, eV, eR, eG, eV, eR], 4, 0, 0, true),
    TileDef("RIVER_CROSSING_B", [eR, eV, eG, eR, eV, eG], 4, 0, 0, true),
    TileDef("GRASS_SLOPE_HIGH", [eG, eG, eG, eG, eG, eG], 20,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 2, false),
    TileDef("ROAD_A_SLOPE_HIGH", [eG, eR, eG, eG, eR, eG], 12,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 2, false),
    TileDef("GRASS_CLIFF", [eG, eG, eG, eG, eG, eG], 6, (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 2, false),
    TileDef("GRASS_CLIFF_C", [eG, eG, eG, eG, eG, eG], 6, (1 << HexDir.E), 2, false),
    TileDef("GRASS_SLOPE_LOW", [eG, eG, eG, eG, eG, eG], 20,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 1, false),
    TileDef("ROAD_A_SLOPE_LOW", [eG, eR, eG, eG, eR, eG], 12,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 1, false),
    TileDef("GRASS_CLIFF_LOW", [eG, eG, eG, eG, eG, eG], 6,
            (1 << HexDir.NE) | (1 << HexDir.E) | (1 << HexDir.SE), 1, false),
    TileDef("GRASS_CLIFF_LOW_C", [eG, eG, eG, eG, eG, eG], 6, (1 << HexDir.E), 1, false),
];

enum size_t numTiles = tileList.length;

/// Look up a tile ID by name; returns -1 if absent. (Cold path: tooling and tests.)
int tileIdByName(string name) @nogc nothrow pure @safe {
    foreach (i, ref t; tileList)
        if (t.name == name)
            return cast(int)i;
    return -1;
}

private bool startsWith(string s, string prefix) @nogc nothrow pure @safe {
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

/// Ground creeps can walk on this tile: grass, roads, slopes and river crossings (bridges).
/// Water, coast, river and cliff tiles block them.
bool groundWalkable(size_t tile) @nogc nothrow pure @safe {
    return groundTable[tile];
}

/// Swimming creeps can cross this tile: open water, coast and river tiles.
bool swimmable(size_t tile) @nogc nothrow pure @safe {
    return swimTable[tile];
}

private immutable bool[numTiles] groundTable = () {
    bool[numTiles] t;
    foreach (i, ref d; tileList)
        t[i] = d.name == "GRASS" || startsWith(d.name, "ROAD_") || d.name == "GRASS_SLOPE_HIGH"
            || d.name == "GRASS_SLOPE_LOW" || startsWith(d.name, "RIVER_CROSSING");
    return t;
}();

private immutable bool[numTiles] swimTable = () {
    bool[numTiles] t;
    foreach (i, ref d; tileList)
        t[i] = d.name == "WATER" || startsWith(d.name, "COAST_") || (startsWith(d.name, "RIVER_")
                && !startsWith(d.name, "RIVER_CROSSING"));
    return t;
}();

@nogc nothrow pure @safe unittest {
    assert(groundWalkable(tileIdByName("GRASS")) && groundWalkable(tileIdByName("ROAD_D")));
    assert(groundWalkable(tileIdByName("ROAD_A_SLOPE_LOW")) && groundWalkable(tileIdByName("RIVER_CROSSING_A")));
    assert(!groundWalkable(tileIdByName("WATER")) && !groundWalkable(tileIdByName("RIVER_A")));
    assert(!groundWalkable(tileIdByName("COAST_B")) && !groundWalkable(tileIdByName("GRASS_CLIFF")));
    assert(swimmable(tileIdByName("WATER")) && swimmable(tileIdByName("RIVER_INTO_COAST")));
    assert(!swimmable(tileIdByName("RIVER_CROSSING_B")) && !swimmable(tileIdByName("GRASS")));
    size_t either = 0;
    foreach (i; 0 .. numTiles)
        if (groundWalkable(i) || swimmable(i))
            either++;
    assert(either == numTiles - 4); // only the four cliff tiles block both
}

/// Rotate edges clockwise by `rotation` steps of 60 degrees (edge i moves to slot i + rotation).
EdgeType[6] rotateHexEdges(const EdgeType[6] edges, int rotation) @nogc nothrow pure @safe {
    EdgeType[6] r;
    foreach (i; 0 .. 6)
        r[(i + rotation) % 6] = edges[i];
    return r;
}

/// Rotate a HexDir bitmask by `rotation` steps.
ubyte rotateDirMask(ubyte mask, int rotation) @nogc nothrow pure @safe {
    ubyte r = 0;
    foreach (i; 0 .. 6)
        if (mask & (1 << i))
            r |= cast(ubyte)(1 << ((i + rotation) % 6));
    return r;
}

/// Edge level for `dir` of a tile placed at `rotation` with `baseLevel`: high edges are raised.
int getEdgeLevel(size_t tile, int rotation, HexDir dir, int baseLevel) @nogc nothrow pure @safe {
    immutable def = &tileList[tile];
    if (!def.isSlope)
        return baseLevel;
    immutable mask = rotateDirMask(def.highEdgeMask, rotation);
    return (mask & (1 << dir)) ? baseLevel + def.levelIncrement : baseLevel;
}

@nogc nothrow pure @safe unittest {
    static assert(numTiles == 34);
    assert(tileIdByName("GRASS") == 0 && tileIdByName("WATER") == 1);
    assert(tileIdByName("NOPE") == -1);
    foreach (ref t; tileList) {
        assert(t.weight > 0);
        assert(t.isSlope == (t.levelIncrement != 0));
        assert(t.levelIncrement <= 2);
    }
}

@nogc nothrow pure @safe unittest {
    EdgeType[6] edges = [eG, eR, eG, eW, eV, eC];
    assert(rotateHexEdges(edges, 0) == edges);
    assert(rotateHexEdges(edges, 6) == edges);
    immutable r1 = rotateHexEdges(edges, 1);
    assert(r1[1] == eG && r1[2] == eR && r1[0] == eC && r1[5] == eV);
    // rotating by a then b equals rotating by a + b
    assert(rotateHexEdges(rotateHexEdges(edges, 2), 3) == rotateHexEdges(edges, 5));
    // a tile with 180-degree symmetry maps to itself under 3 steps
    immutable ra = tileList[tileIdByName("ROAD_A")].edges;
    assert(rotateHexEdges(ra, 3) == ra);
}

@nogc nothrow pure @safe unittest {
    assert(rotateDirMask(0b000111, 0) == 0b000111);
    assert(rotateDirMask(0b000111, 1) == 0b001110);
    assert(rotateDirMask(0b100001, 1) == 0b000011); // wraps NW -> NE
    assert(rotateDirMask(0b000111, 6) == 0b000111);
}

@nogc nothrow pure @safe unittest {
    // GRASS_SLOPE_LOW: high edges NE, E, SE at rotation 0, rise 1.
    immutable t = tileIdByName("GRASS_SLOPE_LOW");
    assert(getEdgeLevel(t, 0, HexDir.NE, 2) == 3);
    assert(getEdgeLevel(t, 0, HexDir.E, 2) == 3);
    assert(getEdgeLevel(t, 0, HexDir.SE, 2) == 3);
    assert(getEdgeLevel(t, 0, HexDir.SW, 2) == 2);
    assert(getEdgeLevel(t, 0, HexDir.NW, 2) == 2);
    // rotated by 3: high edges become SW, W, NW
    assert(getEdgeLevel(t, 3, HexDir.SW, 2) == 3);
    assert(getEdgeLevel(t, 3, HexDir.NE, 2) == 2);
    // rise 2
    immutable h = tileIdByName("GRASS_SLOPE_HIGH");
    assert(getEdgeLevel(h, 0, HexDir.E, 1) == 3);
    // GRASS_CLIFF_C: only E is high
    immutable c = tileIdByName("GRASS_CLIFF_C");
    assert(getEdgeLevel(c, 0, HexDir.E, 0) == 2 && getEdgeLevel(c, 0, HexDir.NE, 0) == 0);
    // flat tile ignores rotation
    assert(getEdgeLevel(0, 4, HexDir.NW, 3) == 3);
}
