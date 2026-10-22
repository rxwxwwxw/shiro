// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from HexWFCCore.js (HexWFCAdjacencyRules). D port for the Shiro engine.
//
// A "state" is a (tile, rotation, baseLevel) triple. All valid states are enumerated once, in
// tile -> rotation -> level order (same as the JS reference), and referenced by dense ID.
module wfc.rules;

import core.bitset : BitSet;
import wfc.hex : HexDir, numHexDirs, opposite;
import wfc.tile_data;

/// 23 flat * 6 * 5 + 6 low slopes * 6 * 4 + 5 high slopes * 6 * 3.
enum size_t numStates = 924;

alias StateSet = BitSet!1024;

struct TileState {
    ubyte tile;
    ubyte rotation;
    ubyte level;
}

/// Edge type and level of one side of a state.
struct EdgeInfo {
    EdgeType type;
    ubyte level;
}

/// Two edges are compatible when type and level both match. (The JS `edgesCompatible` relaxes
/// grass levels, but the solver's byEdge lookups match exactly; we mirror the solver.)
bool edgesCompatible(EdgeType a, int levelA, EdgeType b, int levelB) @nogc nothrow pure @safe {
    return a == b && levelA == levelB;
}

struct AdjacencyRules {
    TileState[numStates] states;
    EdgeInfo[6][numStates] stateEdges;
    /// stateIds[tile][rotation][level]; -1 if that combination is not a valid state.
    short[levelsCount][6][numTiles] stateIds;
    /// byEdge[edgeType][dir][level]: every state whose `dir` edge has that type and level.
    StateSet[levelsCount][6][numEdgeTypes] byEdge;

    @disable this(this);

    /// Builds all tables. Call once at startup.
    static void build(out AdjacencyRules r) @nogc nothrow {
        foreach (ref a; r.stateIds)
            foreach (ref b; a)
                b[] = -1;
        foreach (ref a; r.byEdge)
            foreach (ref b; a)
                foreach (ref s; b)
                    s.reset();

        size_t n = 0;
        foreach (tile; 0 .. numTiles) {
            immutable def = &tileList[tile];
            immutable maxBase = def.isSlope ? levelsCount - 1 - def.levelIncrement : levelsCount - 1;
            foreach (rot; 0 .. 6) {
                immutable edges = rotateHexEdges(def.edges, rot);
                foreach (level; 0 .. maxBase + 1) {
                    assert(n < numStates);
                    r.states[n] = TileState(cast(ubyte)tile, cast(ubyte)rot, cast(ubyte)level);
                    r.stateIds[tile][rot][level] = cast(short)n;
                    foreach (d; 0 .. numHexDirs) {
                        immutable lvl = getEdgeLevel(tile, rot, cast(HexDir)d, level);
                        assert(lvl < levelsCount);
                        r.stateEdges[n][d] = EdgeInfo(edges[d], cast(ubyte)lvl);
                        r.byEdge[edges[d]][d][lvl].set(n);
                    }
                    n++;
                }
            }
        }
        assert(n == numStates);
    }

    /// States of the neighbor that are compatible with edge (type, level) of the cell on side `dir`.
    /// `returnDir` is the neighbor's facing side, i.e. opposite(dir).
    ref const(StateSet) matching(EdgeType type, HexDir returnDir, int level) return const @nogc nothrow pure @safe {
        return byEdge[type][returnDir][level];
    }

    /// Union of neighbor states allowed across `dir` given a set of remaining states in a cell.
    StateSet allowedAcross(const ref StateSet possibilities, HexDir dir) const @nogc nothrow pure @safe {
        StateSet result;
        immutable ret = opposite(dir);
        foreach (s; possibilities.bits) {
            immutable e = stateEdges[s][dir];
            result.unite(byEdge[e.type][ret][e.level]);
        }
        return result;
    }

    int stateId(int tile, int rotation, int level) const @nogc nothrow pure @safe {
        return stateIds[tile][rotation][level];
    }
}

version (unittest) {
    private AdjacencyRules* makeRules() {
        auto r = new AdjacencyRules;
        AdjacencyRules.build(*r);
        return r;
    }
}

unittest {
    auto r = makeRules();
    // Every state ID is dense, unique, and round-trips through stateIds.
    foreach (i; 0 .. numStates) {
        immutable s = r.states[i];
        assert(r.stateId(s.tile, s.rotation, s.level) == i);
    }
    size_t valid = 0;
    foreach (t; 0 .. numTiles)
        foreach (rot; 0 .. 6)
            foreach (l; 0 .. levelsCount)
                if (r.stateIds[t][rot][l] >= 0)
                    valid++;
    assert(valid == numStates);
}

unittest {
    // Counts per category: 690 + 144 + 90.
    auto r = makeRules();
    size_t flat, low, high;
    foreach (ref s; r.states) {
        immutable inc = tileList[s.tile].levelIncrement;
        if (inc == 0)
            flat++;
        else if (inc == 1)
            low++;
        else
            high++;
    }
    assert(flat == 690 && low == 144 && high == 90);
    // Slope base levels never exceed the top level once raised.
    foreach (i; 0 .. numStates)
        foreach (d; 0 .. 6)
            assert(r.stateEdges[i][d].level < levelsCount);
}

unittest {
    // Every state appears in exactly 6 byEdge sets (one per side), matching its stateEdges.
    auto r = makeRules();
    size_t total = 0;
    foreach (t; 0 .. numEdgeTypes)
        foreach (d; 0 .. 6)
            foreach (l; 0 .. levelsCount)
                total += r.byEdge[t][d][l].count;
    assert(total == numStates * 6);
    foreach (i; 0 .. numStates)
        foreach (d; 0 .. 6) {
            immutable e = r.stateEdges[i][d];
            assert(r.byEdge[e.type][d][e.level].test(i));
        }
}

unittest {
    // Symmetry: if A allows B across dir, B allows A across opposite(dir).
    auto r = makeRules();
    foreach (a; 0 .. numStates)
        foreach (d; 0 .. 6) {
            immutable dir = cast(HexDir)d;
            immutable ea = r.stateEdges[a][dir];
            foreach (b; r.matching(ea.type, opposite(dir), ea.level).bits) {
                immutable eb = r.stateEdges[b][opposite(dir)];
                assert(edgesCompatible(ea.type, ea.level, eb.type, eb.level));
                assert(r.matching(eb.type, dir, eb.level).test(a));
            }
        }
}

unittest {
    // Concrete cases: flat grass on level 2 only borders grass at level 2.
    auto r = makeRules();
    immutable g = r.stateId(0, 0, 2);
    assert(g >= 0);
    StateSet one;
    one.set(g);
    foreach (d; 0 .. 6) {
        auto allowed = r.allowedAcross(one, cast(HexDir)d);
        assert(allowed.count > 0);
        foreach (b; allowed.bits) {
            immutable e = r.stateEdges[b][opposite(cast(HexDir)d)];
            assert(e.type == EdgeType.grass && e.level == 2);
        }
    }
    // Water never borders a grass-only state.
    StateSet water;
    water.set(r.stateId(1, 0, 2));
    assert(!r.allowedAcross(water, HexDir.E).test(g));
    // Slope: GRASS_SLOPE_LOW at level 1 rotation 0 is level 2 on NE; its NE neighbor must
    // present a level-2 grass edge on SW.
    immutable slope = tileIdByName("GRASS_SLOPE_LOW");
    StateSet sl;
    sl.set(r.stateId(slope, 0, 1));
    foreach (b; r.allowedAcross(sl, HexDir.NE).bits)
        assert(r.stateEdges[b][HexDir.SW].level == 2);
    foreach (b; r.allowedAcross(sl, HexDir.SW).bits)
        assert(r.stateEdges[b][HexDir.NE].level == 1);
}
