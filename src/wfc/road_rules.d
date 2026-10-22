// Road topology of the tileset, for planning road networks before WFC runs.
//
// A road cell is described by the set of directions its road edges point to (a 6-bit HexDir
// mask). Only some sets exist as tiles: there is no sharp (60 degree) turn, no consecutive
// three-way junction and nothing with four or more exits. Junction and dead-end tiles are
// `preventChaining`, so two cells with the same one of those tiles can never be neighbors.
module wfc.road_rules;

import wfc.hex : HexDir, numHexDirs, opposite;
import wfc.rules;
import wfc.tile_data;

enum RoadShape : ubyte {
    none,
    /// ROAD_END: one exit.
    end,
    /// ROAD_A, road slopes, river crossings: two opposite exits.
    straight,
    /// ROAD_B: two exits 120 degrees apart (a 60 degree turn of heading).
    bend,
    /// ROAD_D: exits {d, d+2, d+4}.
    junctionD,
    /// ROAD_E: three exits with cyclic gaps (1, 3, 2).
    junctionE,
    /// ROAD_F: three exits with cyclic gaps (1, 2, 3).
    junctionF,
    /// No tile has these exits.
    invalid
}

ubyte dirBit(HexDir d) @nogc nothrow pure @safe {
    return cast(ubyte)(1 << d);
}

private RoadShape computeShape(uint mask) @nogc nothrow pure @safe {
    int[6] dirs;
    int n = 0;
    foreach (d; 0 .. 6)
        if (mask & (1 << d))
            dirs[n++] = d;
    if (n == 0)
        return RoadShape.none;
    if (n == 1)
        return RoadShape.end;
    if (n == 2) {
        immutable gap = dirs[1] - dirs[0];
        if (gap == 3)
            return RoadShape.straight;
        if (gap == 2 || gap == 4)
            return RoadShape.bend;
        return RoadShape.invalid;
    }
    if (n == 3) {
        immutable int[3] gaps = [dirs[1] - dirs[0], dirs[2] - dirs[1], 6 - (dirs[2] - dirs[0])];
        if (gaps[0] == 2 && gaps[1] == 2)
            return RoadShape.junctionD;
        foreach (i; 0 .. 3)
            if (gaps[i] == 4)
                return RoadShape.invalid; // three consecutive exits
        foreach (i; 0 .. 3)
            if (gaps[i] == 1)
                return gaps[(i + 1) % 3] == 2 ? RoadShape.junctionF : RoadShape.junctionE;
    }
    return RoadShape.invalid;
}

private immutable RoadShape[64] shapeTable = () {
    RoadShape[64] t;
    foreach (m; 0 .. 64)
        t[m] = computeShape(m);
    return t;
}();

/// Tile shape for a set of road exits.
RoadShape classify(uint dirMask) @nogc nothrow pure @safe {
    return shapeTable[dirMask & 63];
}

/// True if the exits form a real tile (or no road at all).
bool roadMaskValid(uint dirMask) @nogc nothrow pure @safe {
    return classify(dirMask) != RoadShape.invalid;
}

/// Shapes that may not sit next to the same shape (their tiles are `preventChaining`).
bool chains(RoadShape s) @nogc nothrow pure @safe {
    return s == RoadShape.end || s == RoadShape.junctionD || s == RoadShape.junctionE || s == RoadShape.junctionF;
}

/// True if two adjacent cells with these shapes are allowed.
bool chainOk(RoadShape a, RoadShape b) @nogc nothrow pure @safe {
    return !(chains(a) && a == b);
}

/// Number of road exits in a mask.
int exitCount(uint dirMask) @nogc nothrow pure @safe {
    import core.bitop : popcnt;

    return popcnt(dirMask & 63);
}

/// WFC states grouped by their exact set of road exits; index 0 holds every road-free state.
struct RoadMasks {
    StateSet[64] byRoadDirs;
    /// Road exits of each state.
    ubyte[numStates] stateRoadDirs;

    @disable this(this);

    static void build(out RoadMasks m, const(AdjacencyRules)* rules) @nogc nothrow pure @safe {
        foreach (ref s; m.byRoadDirs)
            s.reset();
        foreach (i; 0 .. numStates) {
            ubyte dirs = 0;
            foreach (d; 0 .. numHexDirs)
                if (rules.stateEdges[i][d].type == EdgeType.road)
                    dirs |= cast(ubyte)(1 << d);
            m.stateRoadDirs[i] = dirs;
            m.byRoadDirs[dirs].set(i);
        }
    }

    /// States allowed on a cell whose planned road exits are `dirMask` (0 = no road).
    ref const(StateSet) allowed(uint dirMask) return const @nogc nothrow pure @safe {
        return byRoadDirs[dirMask & 63];
    }
}

@nogc nothrow pure @safe unittest {
    assert(classify(0) == RoadShape.none);
    foreach (d; 0 .. 6) {
        assert(classify(1 << d) == RoadShape.end);
        assert(classify((1 << d) | (1 << ((d + 3) % 6))) == RoadShape.straight);
        assert(classify((1 << d) | (1 << ((d + 2) % 6))) == RoadShape.bend);
        assert(classify((1 << d) | (1 << ((d + 1) % 6))) == RoadShape.invalid);
        assert(classify((1 << d) | (1 << ((d + 1) % 6)) | (1 << ((d + 2) % 6))) == RoadShape.invalid);
    }
    assert(classify(0b010101) == RoadShape.junctionD && classify(0b101010) == RoadShape.junctionD);
    // The tileset's own junctions classify as themselves at rotation 0.
    assert(classify(0b010011) == RoadShape.junctionE); // ROAD_E: NE, E, W
    assert(classify(0b010110) == RoadShape.junctionF); // ROAD_F: E, SE, W
    // Census over all 64 masks: 1 none, 6 ends, 3 straights, 6 bends, 2 + 6 + 6 junctions.
    size_t[RoadShape.max + 1] count;
    foreach (m; 0 .. 64)
        count[classify(m)]++;
    assert(count[RoadShape.none] == 1 && count[RoadShape.end] == 6);
    assert(count[RoadShape.straight] == 3 && count[RoadShape.bend] == 6);
    assert(count[RoadShape.junctionD] == 2 && count[RoadShape.junctionE] == 6 && count[RoadShape.junctionF] == 6);
    assert(count[RoadShape.invalid] == 64 - 30);
    assert(!chainOk(RoadShape.end, RoadShape.end) && chainOk(RoadShape.end, RoadShape.straight));
    assert(chainOk(RoadShape.bend, RoadShape.bend) && !chainOk(RoadShape.junctionE, RoadShape.junctionE));
    assert(chainOk(RoadShape.junctionD, RoadShape.junctionE));
}

unittest {
    // Every valid exit set has WFC states, every invalid one has none, and the states filed
    // under a shape are exactly that shape's tiles.
    auto rules = new AdjacencyRules;
    AdjacencyRules.build(*rules);
    auto m = new RoadMasks;
    RoadMasks.build(*m, rules);
    size_t total = 0;
    foreach (mask; 0 .. 64) {
        total += m.byRoadDirs[mask].count;
        assert(m.byRoadDirs[mask].any == roadMaskValid(mask));
        foreach (s; m.byRoadDirs[mask].bits) {
            immutable name = tileList[rules.states[s].tile].name;
            final switch (classify(mask)) {
            case RoadShape.none:
                break;
            case RoadShape.end:
                assert(name == "ROAD_END");
                break;
            case RoadShape.straight:
                break;
            case RoadShape.bend:
                assert(name == "ROAD_B");
                break;
            case RoadShape.junctionD:
                assert(name == "ROAD_D");
                break;
            case RoadShape.junctionE:
                assert(name == "ROAD_E");
                break;
            case RoadShape.junctionF:
                assert(name == "ROAD_F");
                break;
            case RoadShape.invalid:
                assert(false);
            }
        }
    }
    assert(total == numStates);
    assert(m.allowed(0).count > 500);
}
