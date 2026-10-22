// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Global cell map: one 16-bit state ID per cell in a flat odd-r offset array. Two bytes per cell
// keeps a 2-million-cell map at 4 MB, independent of the solver's per-grid working memory.
module wfc.tile_map;

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memset;
import wfc.grid_connector : MapRect;
import wfc.hex;

struct TileMap {
    MapRect rect;
    private short* data;

    @disable this(this);

    this(MapRect rect) @nogc nothrow @trusted {
        this.rect = rect;
        assert(rect.cols > 0 && rect.rows > 0);
        immutable bytes = rect.cellCount * short.sizeof;
        data = cast(short*)malloc(bytes);
        assert(data !is null, "tile map allocation failed");
        memset(data, 0xFF, bytes); // every cell starts at -1 (unsolved)
    }

    ~this() @nogc nothrow @trusted {
        free(data);
    }

    size_t bytes() const @nogc nothrow pure @safe {
        return rect.cellCount * short.sizeof;
    }

    private size_t index(const CubeCoord c) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        return cast(size_t)o.row * rect.cols + o.col;
    }

    /// State ID at a cell, or -1 if the cell is outside the map or unsolved.
    int get(const CubeCoord c) const @nogc nothrow @trusted {
        if (!rect.contains(c))
            return -1;
        return data[index(c)];
    }

    void set(const CubeCoord c, int stateId) @nogc nothrow @trusted {
        assert(rect.contains(c));
        data[index(c)] = cast(short)stateId;
    }

    size_t countSolved() const @nogc nothrow @trusted {
        size_t n = 0;
        foreach (i; 0 .. rect.cellCount)
            if (data[i] >= 0)
                n++;
        return n;
    }
}

@nogc nothrow unittest {
    auto m = TileMap(MapRect(10, 6));
    assert(m.bytes == 120 && m.countSolved == 0);
    immutable c = offsetToCube(3, 4);
    assert(m.get(c) == -1);
    m.set(c, 77);
    assert(m.get(c) == 77 && m.countSolved == 1);
    // Outside the map reads as unsolved.
    assert(m.get(offsetToCube(-1, 0)) == -1);
    assert(m.get(offsetToCube(10, 0)) == -1);
    assert(m.get(offsetToCube(0, 6)) == -1);
    // Odd rows are shifted but addressing is by offset coordinates, so all cells are distinct.
    foreach (row; 0 .. 6)
        foreach (col; 0 .. 10)
            m.set(offsetToCube(col, row), row * 10 + col);
    foreach (row; 0 .. 6)
        foreach (col; 0 .. 10)
            assert(m.get(offsetToCube(col, row)) == row * 10 + col);
}
