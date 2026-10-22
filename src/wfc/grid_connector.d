// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from src/hexmap/HexGridConnector.js. D port for the Shiro engine.
//
// Grid-of-grids topology. Each "grid" is a radius-R pointy-top hex cluster of cells
// (3R(R+1)+1 cells). Grids tile the plane exactly; their centers form a lattice with six
// neighbors in flat-top directions N, NE, SE, S, SW, NW, addressed with odd-q offset
// coordinates (x, z). All math is integer, so seams are exact for any R and any map size.
//
// The JS reference derives grid centers from floating-point world positions; here the lattice
// is computed in closed form, which gives the same flat-top layout without rounding.
module wfc.grid_connector;

import wfc.hex;

enum GridDir : ubyte {
    N,
    NE,
    SE,
    S,
    SW,
    NW
}

enum size_t numGridDirs = 6;

GridDir opposite(GridDir d) @nogc nothrow pure @safe {
    return cast(GridDir)((d + 3) % 6);
}

/// Odd-q offset coordinates of a grid in the grid-of-grids layout (x = column, z = row).
struct GridCoord {
    int x, z;
}

/// Grid neighbor, honoring odd-q column parity.
GridCoord adjacentGrid(const GridCoord g, GridDir dir) @nogc nothrow pure @safe {
    immutable odd = (g.x & 1) != 0;
    final switch (dir) {
    case GridDir.N:
        return GridCoord(g.x, g.z - 1);
    case GridDir.S:
        return GridCoord(g.x, g.z + 1);
    case GridDir.NE:
        return GridCoord(g.x + 1, odd ? g.z : g.z - 1);
    case GridDir.SE:
        return GridCoord(g.x + 1, odd ? g.z + 1 : g.z);
    case GridDir.SW:
        return GridCoord(g.x - 1, odd ? g.z + 1 : g.z);
    case GridDir.NW:
        return GridCoord(g.x - 1, odd ? g.z : g.z - 1);
    }
}

/// Axial grid coordinates (flat-top): gq = x, gr = z - (x - (x & 1)) / 2.
struct GridAxial {
    int gq, gr;
}

GridAxial toAxial(const GridCoord g) @nogc nothrow pure @safe {
    return GridAxial(g.x, g.z - ((g.x - (g.x & 1)) >> 1));
}

GridCoord toOffset(const GridAxial a) @nogc nothrow pure @safe {
    return GridCoord(a.gq, a.gr + ((a.gq - (a.gq & 1)) >> 1));
}

/// Number of cells in a radius-R grid.
size_t cellsPerGrid(int radius) @nogc nothrow pure @safe {
    return cellsInRadius(radius);
}

// Lattice basis for radius R: SE = (R+1, R), S = (-R, 2R+1) in axial (q, r).
// Determinant = 3R^2 + 3R + 1 = cells per grid, so the clusters tile exactly.
private int latticeDet(int radius) @nogc nothrow pure @safe {
    return 3 * radius * radius + 3 * radius + 1;
}

/// Global cube coordinate of a grid's center cell.
CubeCoord gridCenter(const GridCoord g, int radius) @nogc nothrow pure @safe {
    immutable a = toAxial(g);
    immutable q = a.gq * (radius + 1) - a.gr * radius;
    immutable r = a.gq * radius + a.gr * (2 * radius + 1);
    return CubeCoord.fromAxial(q, r);
}

private int floorDiv(int a, int b) @nogc nothrow pure @safe {
    assert(b > 0);
    immutable q = a / b;
    return (a % b < 0) ? q - 1 : q;
}

/// Grid that owns a global cell. Every cell belongs to exactly one grid.
GridCoord gridOfCell(const CubeCoord c, int radius) @nogc nothrow pure @safe {
    immutable det = latticeDet(radius);
    // Fractional lattice coordinates; one of the four surrounding lattice points is the owner.
    immutable gq0 = floorDiv((2 * radius + 1) * c.q + radius * c.r, det);
    immutable gr0 = floorDiv(-radius * c.q + (radius + 1) * c.r, det);
    foreach (dq; 0 .. 2)
        foreach (dr; 0 .. 2) {
            immutable g = toOffset(GridAxial(gq0 + dq, gr0 + dr));
            if (cubeDistance(c, gridCenter(g, radius)) <= radius)
                return g;
        }
    assert(false, "cell not covered by any grid");
}

/// Local array indices of a cell within its grid's (2R+1)^2 square, as in the JS reference.
struct LocalCoord {
    int x, z;
}

LocalCoord globalToLocal(const CubeCoord c, const CubeCoord center, int radius) @nogc nothrow pure @safe {
    immutable o = cubeToOffset(c - center);
    return LocalCoord(o.col + radius, o.row + radius);
}

CubeCoord localToGlobal(const LocalCoord l, const CubeCoord center, int radius) @nogc nothrow pure @safe {
    return offsetToCube(l.x - radius, l.z - radius) + center;
}

/// Rectangular map in odd-r offset space: columns [0, cols), rows [0, rows).
struct MapRect {
    int cols, rows;

    size_t cellCount() const @nogc nothrow pure @safe {
        return cast(size_t)cols * rows;
    }

    bool contains(const CubeCoord c) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        return o.col >= 0 && o.col < cols && o.row >= 0 && o.row < rows;
    }

    /// Pointy-top world aspect ratio (width / height) with unit hex size: cols*sqrt(3) / (1.5*rows).
    double aspect() const @nogc nothrow pure @safe {
        return cols * 1.7320508075688772 / (1.5 * rows);
    }

    /// Map of about `targetCells` cells whose world-space aspect ratio is `aspectW`:`aspectH`.
    static MapRect withAspect(size_t targetCells, int aspectW, int aspectH) @nogc nothrow pure @safe {
        // cols * rows = N and cols * sqrt(3) / (1.5 * rows) = W / H  =>  rows^2 = N*H*sqrt(3)/(1.5*W)
        immutable rowsSq = targetCells * aspectH * 1.7320508075688772 / (1.5 * aspectW);
        int rows = 1;
        while (cast(double)(rows + 1) * (rows + 1) <= rowsSq)
            rows++;
        immutable cols = cast(int)((targetCells + rows / 2) / rows);
        return MapRect(cols > 0 ? cols : 1, rows);
    }
}

/// Inclusive range of grid axial coordinates covering a rectangle (conservative: some grids at
/// the edge may contain no map cells).
struct GridBounds {
    int minX, maxX, minZ, maxZ;
}

GridBounds gridBoundsForRect(const MapRect rect, int radius) @nogc nothrow pure @safe {
    // Corner cells' owners bound the grid index range; pad by one for the odd-q stagger.
    GridBounds b = GridBounds(int.max, int.min, int.max, int.min);
    immutable int[2] cs = [0, rect.cols - 1];
    immutable int[2] rs = [0, rect.rows - 1];
    foreach (c; cs)
        foreach (r; rs) {
            immutable g = gridOfCell(offsetToCube(c, r), radius);
            if (g.x < b.minX)
                b.minX = g.x;
            if (g.x > b.maxX)
                b.maxX = g.x;
            if (g.z < b.minZ)
                b.minZ = g.z;
            if (g.z > b.maxZ)
                b.maxZ = g.z;
        }
    b.minX -= 1;
    b.maxX += 1;
    b.minZ -= 1;
    b.maxZ += 1;
    return b;
}

/// Writes the cells of grid `g` that lie inside `rect` into `buf`; returns the count.
size_t gridCellsInRect(const GridCoord g, int radius, const MapRect rect, CubeCoord[] buf) @nogc nothrow pure @safe {
    CubeCoord[cellsInRadius(16)] all = void;
    assert(radius <= 16);
    immutable n = cubeCoordsInRadius(gridCenter(g, radius), radius, all[]);
    size_t k = 0;
    foreach (i; 0 .. n)
        if (rect.contains(all[i])) {
            assert(k < buf.length);
            buf[k++] = all[i];
        }
    return k;
}

@nogc nothrow pure @safe unittest {
    // Grid neighbors: opposite round-trips, for both column parities and negative coordinates.
    foreach (x; -3 .. 4)
        foreach (z; -3 .. 4)
            foreach (d; 0 .. numGridDirs) {
                immutable g = GridCoord(x, z);
                immutable dir = cast(GridDir)d;
                assert(adjacentGrid(adjacentGrid(g, dir), opposite(dir)) == g);
            }
    // Offset <-> axial round trip.
    foreach (x; -5 .. 6)
        foreach (z; -5 .. 6) {
            immutable g = GridCoord(x, z);
            assert(toOffset(toAxial(g)) == g);
        }
}

@nogc nothrow pure @safe unittest {
    // Adjacent grid centers are exactly 2R+1 apart, in every direction, for several radii.
    foreach (radius; [1, 2, 4, 8]) {
        foreach (x; -2 .. 3)
            foreach (z; -2 .. 3) {
                immutable g = GridCoord(x, z);
                immutable c0 = gridCenter(g, radius);
                foreach (d; 0 .. numGridDirs)
                    assert(cubeDistance(c0, gridCenter(adjacentGrid(g, cast(GridDir)d), radius)) == 2 * radius + 1);
            }
    }
    // Center of grid (0,0) is the origin.
    assert(gridCenter(GridCoord(0, 0), 8) == CubeCoord(0, 0, 0));
}

@nogc nothrow pure @safe unittest {
    // Flat-top directions: N is straight up (negative world z), S straight down; NE/SE lean east.
    enum radius = 8;
    immutable n = cubeToOffset(gridCenter(adjacentGrid(GridCoord(0, 0), GridDir.N), radius));
    immutable s = cubeToOffset(gridCenter(adjacentGrid(GridCoord(0, 0), GridDir.S), radius));
    immutable ne = cubeToOffset(gridCenter(adjacentGrid(GridCoord(0, 0), GridDir.NE), radius));
    immutable se = cubeToOffset(gridCenter(adjacentGrid(GridCoord(0, 0), GridDir.SE), radius));
    assert(n.row < 0 && s.row > 0 && n.row == -s.row);
    assert(ne.row < 0 && se.row > 0 && ne.col > 0 && se.col > 0);
}

@nogc nothrow pure @safe unittest {
    // Exact tiling: every cell in a large window has exactly one owner within radius, and the
    // owner agrees with gridOfCell; grid sizes sum correctly.
    foreach (radius; [1, 2, 3, 8]) {
        foreach (row; -30 .. 30)
            foreach (col; -30 .. 30) {
                immutable cell = offsetToCube(col, row);
                immutable owner = gridOfCell(cell, radius);
                assert(cubeDistance(cell, gridCenter(owner, radius)) <= radius);
                // uniqueness: no neighboring grid also claims the cell
                foreach (d; 0 .. numGridDirs) {
                    immutable other = adjacentGrid(owner, cast(GridDir)d);
                    assert(cubeDistance(cell, gridCenter(other, radius)) > radius);
                }
            }
    }
}

@nogc nothrow pure @safe unittest {
    // Cells of a grid are all owned by it.
    enum radius = 5;
    CubeCoord[cellsInRadius(radius)] buf;
    immutable g = GridCoord(-3, 4);
    immutable center = gridCenter(g, radius);
    immutable n = cubeCoordsInRadius(center, radius, buf[]);
    assert(n == cellsPerGrid(radius));
    foreach (i; 0 .. n)
        assert(gridOfCell(buf[i], radius) == g);
}

@nogc nothrow pure @safe unittest {
    // Local <-> global round trip.
    enum radius = 8;
    immutable center = gridCenter(GridCoord(2, -1), radius);
    foreach (z; 0 .. 2 * radius + 1)
        foreach (x; 0 .. 2 * radius + 1) {
            immutable g = localToGlobal(LocalCoord(x, z), center, radius);
            assert(globalToLocal(g, center, radius) == LocalCoord(x, z));
        }
}

@nogc nothrow pure @safe unittest {
    // 16:9 maps.
    immutable r = MapRect.withAspect(2_000_000, 16, 9);
    assert(r.cellCount > 1_990_000 && r.cellCount < 2_010_000);
    assert(r.aspect > 1.76 && r.aspect < 1.80);
    immutable s = MapRect.withAspect(4123, 16, 9);
    assert(s.aspect > 1.7 && s.aspect < 1.85);
    // Every rect cell lies in the grid bounds; clipped grid cells are inside the rect and cover
    // the rect exactly once.
    enum radius = 4;
    immutable rect = MapRect(40, 24);
    immutable b = gridBoundsForRect(rect, radius);
    CubeCoord[cellsInRadius(radius)] buf;
    size_t total = 0;
    foreach (z; b.minZ .. b.maxZ + 1)
        foreach (x; b.minX .. b.maxX + 1) {
            immutable n = gridCellsInRect(GridCoord(x, z), radius, rect, buf[]);
            foreach (i; 0 .. n)
                assert(rect.contains(buf[i]));
            total += n;
        }
    assert(total == rect.cellCount);
}
