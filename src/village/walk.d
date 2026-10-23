// Where the player and villagers may walk: per-cell step masks derived from the solved tiles.
// A step from one cell to its neighbor is allowed when both cells are ground (no water, no
// blocking prop) and the two touching tile edges sit at the same level, so slopes connect levels
// and cliffs do not. Model layer: no SDL, @nogc nothrow.
module village.walk;

import core.stdc.stdlib : calloc, free, malloc;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.passability : NavMap, unreachable;
import wfc.rules;
import wfc.tile_data : getEdgeLevel;
import wfc.tile_map;

/// Bit 6 of a cell's mask: something may stand here (bits 0..5: open HexDir steps).
private enum ubyte standBit = 1 << 6;

struct WalkGrid {
    MapRect rect;
    private ubyte* masks;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(masks);
    }

    bool allocated() const @nogc nothrow pure @safe {
        return masks !is null;
    }

    /// Rebuilds the masks from solved tiles and ground passability.
    void build(ref const TileMap tiles, ref const NavMap nav, const(AdjacencyRules)* rules) @nogc nothrow @trusted {
        free(masks);
        rect = tiles.rect;
        masks = cast(ubyte*)calloc(rect.cellCount, 1);
        assert(masks !is null, "walk grid allocation failed");
        foreach (i; 0 .. rect.cellCount) {
            immutable c = rect.cellAt(i);
            if (nav.ground(c))
                masks[i] = standBit;
        }
        foreach (i; 0 .. rect.cellCount) {
            if (!masks[i])
                continue;
            immutable c = rect.cellAt(i);
            immutable st = rules.states[tiles.get(c)];
            foreach (d; 0 .. numHexDirs) {
                immutable dir = cast(HexDir)d;
                immutable n = c.neighbor(dir);
                if (!rect.contains(n) || !masks[rect.index(n)])
                    continue;
                immutable ns = rules.states[tiles.get(n)];
                if (getEdgeLevel(st.tile, st.rotation, dir, st.level) == getEdgeLevel(ns.tile,
                        ns.rotation, opposite(dir), ns.level))
                    masks[i] |= cast(ubyte)(1 << d);
            }
        }
    }

    bool standable(const CubeCoord c) const @nogc nothrow @trusted {
        return masks !is null && rect.contains(c) && (masks[rect.index(c)] & standBit) != 0;
    }

    bool canStep(const CubeCoord c, HexDir d) const @nogc nothrow @trusted {
        return masks !is null && rect.contains(c) && (masks[rect.index(c)] & (1 << d)) != 0;
    }

    /// Steps from `from` to every cell (`unreachable` where no walk leads); `dist` must hold
    /// rect.cellCount entries. Returns the number of cells reached.
    size_t distances(const CubeCoord from, ushort[] dist) const @nogc nothrow @trusted {
        assert(dist.length >= rect.cellCount);
        dist[0 .. rect.cellCount] = unreachable;
        if (!standable(from))
            return 0;
        auto queue = cast(uint*)malloc(rect.cellCount * uint.sizeof);
        assert(queue !is null, "walk queue allocation failed");
        scope (exit)
            free(queue);
        size_t head = 0, tail = 0;
        dist[rect.index(from)] = 0;
        queue[tail++] = cast(uint)rect.index(from);
        while (head < tail) {
            immutable i = queue[head++];
            immutable c = rect.cellAt(i);
            foreach (d; 0 .. numHexDirs) {
                if (!(masks[i] & (1 << d)))
                    continue;
                immutable j = rect.index(c.neighbor(cast(HexDir)d));
                if (dist[j] != unreachable)
                    continue;
                dist[j] = cast(ushort)(dist[i] + 1);
                queue[tail++] = cast(uint)j;
            }
        }
        return tail;
    }
}

@nogc nothrow unittest {
    import wfc.map_session : MapSession;
    import wfc.tile_data : tileIdByName;

    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    const rules = s.rules;
    immutable grass = tileIdByName("GRASS"), water = tileIdByName("WATER");
    // A 4 x 2 strip: grass at level 0 except a level-1 cell (a cliff) and one water cell.
    auto tiles = TileMap(MapRect(4, 2));
    foreach (row; 0 .. 2)
        foreach (col; 0 .. 4)
            tiles.set(offsetToCube(col, row), rules.stateId(grass, 0, 0));
    tiles.set(offsetToCube(2, 0), rules.stateId(grass, 0, 1));
    tiles.set(offsetToCube(3, 1), rules.stateId(water, 0, 0));
    NavMap nav;
    nav.rect = tiles.rect;
    foreach (row; 0 .. 2)
        foreach (col; 0 .. 4)
            nav.setForTest(offsetToCube(col, row), (col == 3 && row == 1) ? 0 : 1);
    WalkGrid w;
    w.build(tiles, nav, rules);
    immutable a = offsetToCube(0, 0), b = offsetToCube(1, 0), cliff = offsetToCube(2, 0);
    assert(w.standable(a) && w.standable(cliff) && !w.standable(offsetToCube(3, 1)));
    assert(w.canStep(a, HexDir.E) && !w.canStep(b, HexDir.E) && !w.canStep(cliff, HexDir.W));
    ushort[8] dist;
    // Everything but the cliff top and the water is reachable at level 0.
    assert(w.distances(a, dist[]) == 6);
    assert(dist[tiles.rect.index(cliff)] == unreachable && dist[tiles.rect.index(offsetToCube(3, 0))] != unreachable);
    assert(w.distances(offsetToCube(3, 1), dist[]) == 0);
}
