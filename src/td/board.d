// The playing field a game runs on, distilled from a generated map: per-cell walk / build flags,
// elevation, special tiles and the creep distance field to the sinks. Built once per game, so the
// tick never touches the WFC data structures. Headless Model.
module td.board;

import core.stdc.stdlib : calloc, malloc, free;
import td.defs;
import wfc.decorations : DecoKind;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.map_session : MapSession;
import wfc.passability : NavFlag, unreachable;
import wfc.placement : maxSinks, maxSources;
import wfc.tile_data : swimmable;

enum CellFlag : ubyte {
    /// A tower (or, on a gold vein, a mine) may stand here.
    buildable = 1,
    /// Creeps walk here.
    walk = 2,
    road = 4,
    source = 8,
    sink = 16
}

struct Board {
    MapRect rect;
    private ubyte* flags;
    private ubyte* levels;
    private ubyte* specials;
    private ushort* sinkDist;
    /// Sources with a path to a sink, and the sinks.
    CubeCoord[maxSources] sources;
    int numSources;
    CubeCoord[maxSinks] sinks;
    int numSinks;
    int goldVeins, leyStones;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        release();
    }

    private void release() @nogc nothrow @trusted {
        free(flags);
        free(levels);
        free(specials);
        free(sinkDist);
        flags = levels = specials = null;
        sinkDist = null;
    }

    bool allocated() const @nogc nothrow pure @safe {
        return flags !is null;
    }

    /// Fresh board of `r` with every cell blocked.
    void allocate(MapRect r) @nogc nothrow @trusted {
        release();
        rect = r;
        immutable n = r.cellCount;
        flags = cast(ubyte*)calloc(n, 1);
        levels = cast(ubyte*)calloc(n, 1);
        specials = cast(ubyte*)calloc(n, 1);
        sinkDist = cast(ushort*)malloc(n * ushort.sizeof);
        assert(flags && levels && specials && sinkDist, "board allocation failed");
        numSources = numSinks = goldVeins = leyStones = 0;
    }

    /// Board of a generated map; `seed` places the special tiles.
    void load(ref const MapSession s, uint seed) @nogc nothrow @trusted {
        allocate(s.tiles.rect);
        const rules = s.rules;
        const net = &s.network();
        foreach (i; 0 .. rect.cellCount) {
            immutable c = rect.cellAt(i);
            immutable id = s.tiles.get(c);
            if (id < 0 || !s.inMap(c))
                continue;
            immutable st = rules.states[id];
            levels[i] = st.level;
            immutable nav = s.nav.get(c);
            ubyte f = 0;
            if (nav & NavFlag.ground)
                f |= CellFlag.walk;
            if (nav & NavFlag.road)
                f |= CellFlag.road;
            if (nav & NavFlag.source)
                f |= CellFlag.source;
            if (nav & NavFlag.sink)
                f |= CellFlag.sink;
            immutable deco = s.decorations.get(c).kind;
            immutable onNet = net.allocated && net.onNetwork(c);
            if (!onNet && !s.tiles.isMountain(c) && !swimmable(st.tile) && (deco == DecoKind.none
                    || deco == DecoKind.tree || deco == DecoKind.rock))
                f |= CellFlag.buildable;
            flags[i] = f;
        }
        finish(seed, true);
    }

    /// Test hook: sets one cell.
    void setCell(int col, int row, ubyte f, int level = 0) @nogc nothrow @trusted {
        immutable i = cast(size_t)row * rect.cols + col;
        flags[i] = f;
        levels[i] = cast(ubyte)level;
    }

    /// Computes the distance field and endpoint lists from the flags, then (optionally) places
    /// special tiles.
    void finish(uint seed, bool placeSpecials) @nogc nothrow @trusted {
        computeSinkDist();
        numSources = numSinks = 0;
        foreach (i; 0 .. rect.cellCount) {
            if ((flags[i] & CellFlag.sink) && numSinks < maxSinks)
                sinks[numSinks++] = rect.cellAt(i);
            if ((flags[i] & CellFlag.source) && sinkDist[i] != unreachable && numSources < maxSources)
                sources[numSources++] = rect.cellAt(i);
        }
        if (placeSpecials)
            this.placeSpecials(seed);
    }

    private void computeSinkDist() @nogc nothrow @trusted {
        immutable n = rect.cellCount;
        sinkDist[0 .. n] = unreachable;
        auto queue = cast(uint*)malloc(n * uint.sizeof);
        assert(queue !is null);
        scope (exit)
            free(queue);
        size_t head = 0, tail = 0;
        foreach (i; 0 .. n)
            if ((flags[i] & (CellFlag.sink | CellFlag.walk)) == (CellFlag.sink | CellFlag.walk)) {
                sinkDist[i] = 0;
                queue[tail++] = cast(uint)i;
            }
        while (head < tail) {
            immutable i = queue[head++];
            immutable c = rect.cellAt(i);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                if (!rect.contains(nc))
                    continue;
                immutable j = rect.index(nc);
                if (sinkDist[j] != unreachable || !(flags[j] & CellFlag.walk))
                    continue;
                sinkDist[j] = cast(ushort)(sinkDist[i] + 1);
                queue[tail++] = cast(uint)j;
            }
        }
    }

    /// Gold veins and ley stones on buildable cells two to four steps from a road, kept apart from
    /// each other; counts scale with the map.
    private void placeSpecials(uint seed) @nogc nothrow @trusted {
        immutable n = rect.cellCount;
        specials[0 .. n] = SpecialKind.none;
        goldVeins = leyStones = 0;
        // Distance to the nearest road cell (capped), by BFS.
        auto rd = cast(ubyte*)malloc(n);
        auto queue = cast(uint*)malloc(n * uint.sizeof);
        assert(rd !is null && queue !is null);
        scope (exit) {
            free(rd);
            free(queue);
        }
        rd[0 .. n] = 255;
        size_t head = 0, tail = 0;
        foreach (i; 0 .. n)
            if (flags[i] & CellFlag.road) {
                rd[i] = 0;
                queue[tail++] = cast(uint)i;
            }
        while (head < tail) {
            immutable i = queue[head++];
            if (rd[i] >= 5)
                continue;
            immutable c = rect.cellAt(i);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                if (!rect.contains(nc))
                    continue;
                immutable j = rect.index(nc);
                if (rd[j] != 255)
                    continue;
                rd[j] = cast(ubyte)(rd[i] + 1);
                queue[tail++] = cast(uint)j;
            }
        }
        size_t candidates = 0;
        foreach (i; 0 .. n)
            if ((flags[i] & CellFlag.buildable) && rd[i] >= 2 && rd[i] <= 4)
                candidates++;
        int want(size_t per, int lo, int hi) {
            immutable k = cast(int)(candidates / per);
            return k < lo ? lo : (k > hi ? hi : k);
        }

        immutable veins = want(120, 2, 16), ley = want(160, 2, 10);
        enum int spacing = 5;
        CubeCoord[26] placed;
        int np = 0;
        foreach (round; 0 .. veins + ley) {
            immutable kind = round % 2 == 0 && goldVeins < veins ? SpecialKind.goldVein
                : (leyStones < ley ? SpecialKind.leyStone : SpecialKind.goldVein);
            uint best = 0;
            size_t bestI = size_t.max;
            foreach (i; 0 .. n) {
                if (!(flags[i] & CellFlag.buildable) || rd[i] < 2 || rd[i] > 4 || specials[i])
                    continue;
                immutable h = mix(seed ^ 0x5EC1A1u, cast(uint)i, kind) | 1;
                if (h <= best)
                    continue;
                immutable c = rect.cellAt(i);
                bool near = false;
                foreach (k; 0 .. np)
                    near |= cubeDistance(placed[k], c) < spacing;
                if (near)
                    continue;
                best = h;
                bestI = i;
            }
            if (bestI == size_t.max)
                break;
            specials[bestI] = kind;
            placed[np++] = rect.cellAt(bestI);
            if (kind == SpecialKind.goldVein)
                goldVeins++;
            else
                leyStones++;
        }
    }

    bool inside(int col, int row) const @nogc nothrow pure @safe {
        return col >= 0 && row >= 0 && col < rect.cols && row < rect.rows;
    }

    ubyte flagsAt(size_t i) const @nogc nothrow @trusted {
        return flags[i];
    }

    int levelAt(size_t i) const @nogc nothrow @trusted {
        return levels[i];
    }

    SpecialKind specialAt(size_t i) const @nogc nothrow @trusted {
        return cast(SpecialKind)specials[i];
    }

    SpecialKind special(int col, int row) const @nogc nothrow @trusted {
        return inside(col, row) ? specialAt(cast(size_t)row * rect.cols + col) : SpecialKind.none;
    }

    /// Steps to the nearest sink along walkable cells (`unreachable` if none).
    ushort distAt(size_t i) const @nogc nothrow @trusted {
        return sinkDist[i];
    }

    /// Test hook.
    void setSpecial(int col, int row, SpecialKind k) @nogc nothrow @trusted {
        specials[cast(size_t)row * rect.cols + col] = k;
    }

    /// Range bonus in percent for a tower on cell `i`: its height over the nearest road within
    /// four steps.
    int highGroundPct(size_t i) const @nogc nothrow @trusted {
        CubeCoord[61] ring = void;
        immutable c = rect.cellAt(i);
        foreach (r; 1 .. 5) {
            immutable cnt = cubeCoordsInRadius(c, r, ring[]);
            int roadLevel = int.max;
            foreach (k; 0 .. cnt) {
                if (!rect.contains(ring[k]) || cubeDistance(ring[k], c) != r)
                    continue;
                immutable j = rect.index(ring[k]);
                if ((flags[j] & CellFlag.road) && levels[j] < roadLevel)
                    roadLevel = levels[j];
            }
            if (roadLevel != int.max) {
                immutable diff = levels[i] - roadLevel;
                immutable pct = diff * highGroundPctPerLevel;
                return pct < 0 ? 0 : (pct > highGroundCapPct ? highGroundCapPct : pct);
            }
        }
        return 0;
    }
}

@nogc nothrow unittest {
    // A straight road from a source at col 1 to a sink at col 8, a raised ledge above it.
    Board b;
    b.allocate(MapRect(10, 5));
    foreach (col; 1 .. 9)
        b.setCell(col, 2, CellFlag.walk | CellFlag.road | (col == 1 ? CellFlag.source : 0) | (col == 8
                ? CellFlag.sink : 0), 1);
    foreach (col; 0 .. 10) {
        b.setCell(col, 0, CellFlag.buildable, 3);
        b.setCell(col, 1, CellFlag.buildable, 2);
        b.setCell(col, 4, CellFlag.buildable, 0);
    }
    b.finish(1, false);
    assert(b.numSources == 1 && b.numSinks == 1);
    assert(b.distAt(b.rect.index(offsetToCube(1, 2))) == 7);
    assert(b.distAt(b.rect.index(offsetToCube(8, 2))) == 0);
    assert(b.distAt(b.rect.index(offsetToCube(4, 0))) == unreachable);
    // Two levels above the road: +24%; one: +12%; below it: nothing.
    assert(b.highGroundPct(b.rect.index(offsetToCube(4, 0))) == 24);
    assert(b.highGroundPct(b.rect.index(offsetToCube(4, 1))) == 12);
    assert(b.highGroundPct(b.rect.index(offsetToCube(4, 4))) == 0);
}

@nogc nothrow unittest {
    import wfc.map_session : GenParams;

    // Generated maps: specials sit on buildable cells near roads, apart, and depend only on the seed.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 64;
    p.rows = 40;
    p.radius = 6;
    p.seed = 5;
    assert(s.regenerate(p).isOk);
    Board a, b;
    a.load(*s, 9);
    b.load(*s, 9);
    assert(a.numSources == p.routes.place.sources && a.numSinks == p.routes.place.sinks);
    assert(a.goldVeins >= 2 && a.leyStones >= 2);
    size_t veins = 0;
    foreach (i; 0 .. a.rect.cellCount) {
        assert(a.specialAt(i) == b.specialAt(i));
        if (a.specialAt(i) == SpecialKind.none)
            continue;
        veins += a.specialAt(i) == SpecialKind.goldVein;
        assert(a.flagsAt(i) & CellFlag.buildable);
        foreach (j; i + 1 .. a.rect.cellCount)
            if (a.specialAt(j) != SpecialKind.none)
                assert(cubeDistance(a.rect.cellAt(i), a.rect.cellAt(j)) >= 5);
    }
    assert(veins == a.goldVeins);
    // Every source can walk to a sink.
    foreach (k; 0 .. a.numSources)
        assert(a.distAt(a.rect.index(a.sources[k])) != unreachable);
}
