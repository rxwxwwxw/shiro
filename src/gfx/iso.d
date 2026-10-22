// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine (View layer).
//
// Pseudo-3D projection of the hex map: world (x, z) uses the reference implementation's unit
// layout (hex width 2, row pitch sqrt(3)); elevation lifts points straight up the screen.
module gfx.iso;

import wfc.hex : HexDir, numHexDirs;
import wfc.rules : EdgeInfo;

/// Circumradius of a pointy-top hex of width 2.
enum float hexRadius = 1.1547005f;
/// Vertical foreshortening of the ground plane (1 = straight top-down).
enum float squash = 0.62f;
/// Screen lift per elevation level, in world units.
enum float levelStep = 0.45f;
enum float rowPitch = 1.7320508f;

struct IsoPoint {
    float x, y;
}

/// Corner k of a pointy-top hex sits at angle -90 + 60k degrees (k = 0 is the top corner), so
/// edge HexDir d spans corners d and d + 1. Offsets are (x, z) from the cell center.
immutable float[2][6] cornerOffsets = [
    [0.0f, -hexRadius], [1.0f, -hexRadius / 2], [1.0f, hexRadius / 2], [0.0f, hexRadius],
    [-1.0f, hexRadius / 2], [-1.0f, -hexRadius / 2]
];

/// World-space center of an odd-r offset cell.
void cellCenter(int col, int row, out float x, out float z) @nogc nothrow pure @safe {
    x = col * 2.0f + (row & 1);
    z = row * rowPitch;
}

IsoPoint project(float x, float z, float h) @nogc nothrow pure @safe {
    return IsoPoint(x, z * squash - h * levelStep);
}

/// Heights (in levels) of the six corners and the center (index 6) of a tile. Corner k touches
/// edges k - 1 and k: ramps average the two, cliffs take the higher one for a hard step.
float[7] cornerHeights(const ref EdgeInfo[6] edges, bool cliff) @nogc nothrow pure @safe {
    float[7] h;
    float sum = 0;
    foreach (k; 0 .. numHexDirs) {
        immutable a = edges[(k + 5) % 6].level;
        immutable b = edges[k].level;
        h[k] = cliff ? (a > b ? a : b) : (a + b) * 0.5f;
        sum += h[k];
    }
    h[6] = sum / 6;
    if (cliff) {
        // The plateau holds the center unless only a sliver of the tile is raised.
        int lo = edges[0].level, hi = edges[0].level, highEdges = 0;
        foreach (ref e; edges) {
            lo = e.level < lo ? e.level : lo;
            hi = e.level > hi ? e.level : hi;
        }
        foreach (ref e; edges)
            highEdges += e.level == hi;
        h[6] = highEdges >= 3 ? hi : lo;
    }
    return h;
}

/// Corner of the neighbor across edge `d` that coincides with our corner `k` (k = d or d + 1).
int sharedCorner(HexDir d, int k) @nogc nothrow pure @safe {
    assert(k == d || k == (d + 1) % 6);
    return k == d ? (d + 4) % 6 : (d + 3) % 6;
}

@nogc nothrow pure @safe unittest {
    // Corners are on the circumradius and consecutive corners are one side length apart.
    foreach (k; 0 .. 6) {
        immutable a = cornerOffsets[k], b = cornerOffsets[(k + 1) % 6];
        immutable r2 = a[0] * a[0] + a[1] * a[1];
        assert(r2 > hexRadius * hexRadius - 1e-4f && r2 < hexRadius * hexRadius + 1e-4f);
        immutable s2 = (a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]);
        assert(s2 > hexRadius * hexRadius - 1e-4f && s2 < hexRadius * hexRadius + 1e-4f);
    }
}

@nogc nothrow pure @safe unittest {
    import wfc.hex : cubeDirs, offsetToCube, cubeToOffset;

    // Shared corners coincide in world space for every direction and both row parities.
    foreach (row; 0 .. 2)
        foreach (d; 0 .. 6) {
            immutable c = offsetToCube(3, row);
            immutable o = cubeToOffset(c.neighbor(cast(HexDir)d));
            float x0, z0, x1, z1;
            cellCenter(3, row, x0, z0);
            cellCenter(o.col, o.row, x1, z1);
            immutable int[2] ks = [d, (d + 1) % 6];
            foreach (k; ks) {
                immutable n = sharedCorner(cast(HexDir)d, k);
                immutable dx = x0 + cornerOffsets[k][0] - (x1 + cornerOffsets[n][0]);
                immutable dz = z0 + cornerOffsets[k][1] - (z1 + cornerOffsets[n][1]);
                assert(dx * dx + dz * dz < 1e-6f);
            }
        }
}

@nogc nothrow pure @safe unittest {
    import wfc.tile_data : EdgeType;

    // A low ramp raised on NE, E, SE: the right corners are high, the left ones low.
    EdgeInfo[6] e;
    foreach (i, ref x; e)
        x = EdgeInfo(EdgeType.grass, cast(ubyte)(i < 3 ? 2 : 1));
    immutable h = cornerHeights(e, false);
    assert(h[1] == 2 && h[2] == 2 && h[4] == 1 && h[5] == 1 && h[0] == 1.5f && h[3] == 1.5f);
    assert(h[6] == 1.5f);
    immutable c = cornerHeights(e, true);
    assert(c[0] == 2 && c[3] == 2 && c[4] == 1 && c[6] == 2);
    // Flat tiles are flat.
    foreach (ref x; e)
        x.level = 3;
    foreach (v; cornerHeights(e, false))
        assert(v == 3);
}
