// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Hex coordinate math after Amit Patel / Red Blob Games. D port for the Shiro engine.
//
// Pointy-top tiles, odd-r offset (col, row) <-> cube (q, r, s), q + r + s == 0.
module wfc.hex;

/// Pointy-top directions, in HexWFC order.
enum HexDir : ubyte {
    NE,
    E,
    SE,
    SW,
    W,
    NW
}

enum size_t numHexDirs = 6;

/// Direction pointing the opposite way.
HexDir opposite(HexDir d) @nogc nothrow pure @safe {
    return cast(HexDir)((d + 3) % 6);
}

/// Rotate a direction clockwise by `steps` * 60 degrees.
HexDir rotated(HexDir d, int steps) @nogc nothrow pure @safe {
    return cast(HexDir)(((d + steps) % 6 + 6) % 6);
}

struct OffsetCoord {
    int col, row;
}

struct CubeCoord {
    int q, r, s;

    this(int q, int r, int s) @nogc nothrow pure @safe {
        assert(q + r + s == 0, "cube coordinates must satisfy q + r + s == 0");
        this.q = q;
        this.r = r;
        this.s = s;
    }

    /// Axial constructor: s is derived.
    static CubeCoord fromAxial(int q, int r) @nogc nothrow pure @safe {
        return CubeCoord(q, r, -q - r);
    }

    bool isValid() const @nogc nothrow pure @safe {
        return q + r + s == 0;
    }

    CubeCoord opBinary(string op : "+")(const CubeCoord o) const @nogc nothrow pure @safe {
        return CubeCoord(q + o.q, r + o.r, s + o.s);
    }

    CubeCoord opBinary(string op : "-")(const CubeCoord o) const @nogc nothrow pure @safe {
        return CubeCoord(q - o.q, r - o.r, s - o.s);
    }

    CubeCoord neighbor(HexDir d) const @nogc nothrow pure @safe {
        immutable v = cubeDirs[d];
        return CubeCoord(q + v.q, r + v.r, s + v.s);
    }
}

/// Neighbor vectors in HexDir order: NE, E, SE, SW, W, NW.
immutable CubeCoord[6] cubeDirs = [
    CubeCoord(1, -1, 0), CubeCoord(1, 0, -1), CubeCoord(0, 1, -1), CubeCoord(-1, 1, 0),
    CubeCoord(-1, 0, 1), CubeCoord(0, -1, 1)
];

/// Odd-r offset -> cube.
CubeCoord offsetToCube(int col, int row) @nogc nothrow pure @safe {
    immutable q = col - (row >> 1);
    return CubeCoord(q, row, -q - row);
}

CubeCoord toCube(const OffsetCoord o) @nogc nothrow pure @safe {
    return offsetToCube(o.col, o.row);
}

/// Cube -> odd-r offset.
OffsetCoord cubeToOffset(const CubeCoord c) @nogc nothrow pure @safe {
    return OffsetCoord(c.q + (c.r >> 1), c.r);
}

int cubeDistance(const CubeCoord a, const CubeCoord b) @nogc nothrow pure @safe {
    immutable dq = a.q > b.q ? a.q - b.q : b.q - a.q;
    immutable dr = a.r > b.r ? a.r - b.r : b.r - a.r;
    immutable ds = a.s > b.s ? a.s - b.s : b.s - a.s;
    return dq > dr ? (dq > ds ? dq : ds) : (dr > ds ? dr : ds);
}

/// Number of cells within `radius` of a center: 3r(r+1) + 1.
size_t cellsInRadius(int radius) @nogc nothrow pure @safe {
    assert(radius >= 0);
    return cast(size_t)(3 * radius * (radius + 1) + 1);
}

/// Writes all cells within `radius` of `center` into `buf` (q-major, r ascending, like the JS
/// reference) and returns the count. `buf` must hold at least cellsInRadius(radius) entries.
size_t cubeCoordsInRadius(const CubeCoord center, int radius, CubeCoord[] buf) @nogc nothrow pure @safe {
    immutable n = cellsInRadius(radius);
    assert(buf.length >= n);
    size_t k = 0;
    foreach (dq; -radius .. radius + 1) {
        immutable rlo = -radius > -dq - radius ? -radius : -dq - radius;
        immutable rhi = radius < -dq + radius ? radius : -dq + radius;
        foreach (dr; rlo .. rhi + 1)
            buf[k++] = CubeCoord(center.q + dq, center.r + dr, center.s - dq - dr);
    }
    assert(k == n);
    return k;
}

/// Direction from `a` to adjacent `b`; returns false if not adjacent.
bool directionTo(const CubeCoord a, const CubeCoord b, out HexDir dir) @nogc nothrow pure @safe {
    foreach (i; 0 .. numHexDirs) {
        if (a.neighbor(cast(HexDir)i) == b) {
            dir = cast(HexDir)i;
            return true;
        }
    }
    return false;
}

@nogc nothrow pure @safe unittest {
    // Offset <-> cube round trip, including negative rows/cols.
    foreach (row; -10 .. 11)
        foreach (col; -10 .. 11) {
            immutable c = offsetToCube(col, row);
            assert(c.isValid);
            immutable o = cubeToOffset(c);
            assert(o.col == col && o.row == row);
        }
    // Known values (odd-r): row 1 is shifted right by half a hex.
    assert(offsetToCube(0, 0) == CubeCoord(0, 0, 0));
    assert(offsetToCube(2, 1) == CubeCoord(2, 1, -3));
    assert(offsetToCube(0, -1) == CubeCoord(1, -1, 0));
}

@nogc nothrow pure @safe unittest {
    // Directions: opposites cancel, rotation is cyclic, neighbors are at distance 1.
    immutable origin = CubeCoord(0, 0, 0);
    foreach (i; 0 .. numHexDirs) {
        immutable d = cast(HexDir)i;
        assert(cubeDirs[d].isValid);
        immutable n = origin.neighbor(d);
        assert(cubeDistance(origin, n) == 1);
        assert(n.neighbor(opposite(d)) == origin);
        assert(opposite(opposite(d)) == d);
        assert(rotated(d, 6) == d && rotated(d, -6) == d);
        assert(rotated(rotated(d, 2), -2) == d);
        HexDir back;
        assert(origin.directionTo(n, back) && back == d);
    }
    assert(rotated(HexDir.NE, 1) == HexDir.E);
    assert(rotated(HexDir.NE, -1) == HexDir.NW);
    HexDir dummy;
    assert(!origin.directionTo(CubeCoord(2, -2, 0), dummy));
}

@nogc nothrow pure @safe unittest {
    // Pointy-top geometry: NE and E neighbors in offset space on an even row.
    immutable c = offsetToCube(3, 2);
    assert(cubeToOffset(c.neighbor(HexDir.E)) == OffsetCoord(4, 2));
    assert(cubeToOffset(c.neighbor(HexDir.W)) == OffsetCoord(2, 2));
    assert(cubeToOffset(c.neighbor(HexDir.NE)) == OffsetCoord(3, 1));
    assert(cubeToOffset(c.neighbor(HexDir.NW)) == OffsetCoord(2, 1));
    assert(cubeToOffset(c.neighbor(HexDir.SE)) == OffsetCoord(3, 3));
    assert(cubeToOffset(c.neighbor(HexDir.SW)) == OffsetCoord(2, 3));
    // Odd row shifts the other way.
    immutable d = offsetToCube(3, 3);
    assert(cubeToOffset(d.neighbor(HexDir.NE)) == OffsetCoord(4, 2));
    assert(cubeToOffset(d.neighbor(HexDir.SW)) == OffsetCoord(3, 4));
}

@nogc nothrow pure @safe unittest {
    // Metric invariants.
    foreach (a; -3 .. 4)
        foreach (b; -3 .. 4) {
            immutable p = CubeCoord.fromAxial(a, b);
            immutable q = CubeCoord.fromAxial(b, a - b);
            assert(cubeDistance(p, p) == 0);
            assert(cubeDistance(p, q) == cubeDistance(q, p));
            assert(cubeDistance(p, CubeCoord(0, 0, 0)) <= cubeDistance(p, q) + cubeDistance(q, CubeCoord(0, 0, 0)));
        }
    assert(cubeDistance(CubeCoord(0, 0, 0), CubeCoord(3, -5, 2)) == 5);
}

@nogc nothrow pure @safe unittest {
    // Radius queries: counts, uniqueness, distance bound, ring structure.
    CubeCoord[217] buf; // radius 8, the WFC grid size
    foreach (radius; 0 .. 9) {
        immutable center = offsetToCube(-2, 3);
        immutable n = cubeCoordsInRadius(center, radius, buf[]);
        assert(n == cellsInRadius(radius));
        foreach (i; 0 .. n) {
            assert(buf[i].isValid);
            assert(cubeDistance(center, buf[i]) <= radius);
            foreach (j; 0 .. i)
                assert(buf[i] != buf[j]);
        }
    }
    assert(cellsInRadius(8) == 217 && cellsInRadius(2) == 19 && cellsInRadius(1) == 7);
    // Every neighbor of the center is included for radius 1.
    immutable n1 = cubeCoordsInRadius(CubeCoord(0, 0, 0), 1, buf[]);
    foreach (i; 0 .. numHexDirs) {
        bool found = false;
        foreach (j; 0 .. n1)
            if (buf[j] == cubeDirs[i])
                found = true;
        assert(found);
    }
}
