// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from HexWFCCore.js (HexWFCCell). D port for the Shiro engine.
module wfc.cell;

import core.random : Random;
import wfc.rules : StateSet, numStates;

/// Possibility space of one cell: a bitset of remaining state IDs plus its collapsed state.
struct HexWFCCell {
    StateSet possibilities;
    bool collapsed;
    /// Collapsed state ID, or -1.
    short state = -1;

    /// Resets to the full possibility space of `n` states (IDs 0 .. n-1).
    void reset(size_t n = numStates) @nogc nothrow pure @safe {
        possibilities.setFirst(n);
        collapsed = false;
        state = -1;
    }

    size_t count() const @nogc nothrow pure @safe {
        return possibilities.count;
    }

    bool has(size_t stateId) const @nogc nothrow pure @safe {
        return possibilities.test(stateId);
    }

    /// Removes a state; returns true if it was present.
    bool remove(size_t stateId) @nogc nothrow pure @safe {
        if (!possibilities.test(stateId))
            return false;
        possibilities.clear(stateId);
        return true;
    }

    void collapse(size_t stateId) @nogc nothrow pure @safe {
        possibilities.reset();
        possibilities.set(stateId);
        collapsed = true;
        state = cast(short)stateId;
    }

    /// Sort key for lowest-entropy search: fewer possibilities sort first, ties are broken by a
    /// random perturbation (integer counterpart of JS `log(count) + random() * 0.001`, which keeps
    /// the ordering identical on every platform). Collapsed cells return 0.
    uint entropyKey(ref Random rng) const @nogc nothrow pure @safe {
        if (collapsed)
            return 0;
        return cast(uint)(count << 20) | (rng.next() >>> 12);
    }
}

@nogc nothrow pure @safe unittest {
    HexWFCCell c;
    c.reset();
    assert(c.count == numStates && !c.collapsed && c.state == -1);
    assert(c.has(0) && c.has(numStates - 1));
    assert(c.remove(5) && !c.remove(5));
    assert(c.count == numStates - 1 && !c.has(5));
    c.reset(10);
    assert(c.count == 10 && !c.has(10));
}

@nogc nothrow pure @safe unittest {
    HexWFCCell c;
    c.reset();
    c.collapse(42);
    assert(c.collapsed && c.state == 42 && c.count == 1 && c.has(42));
    auto rng = Random(1);
    assert(c.entropyKey(rng) == 0);
}

@nogc nothrow pure @safe unittest {
    // Fewer possibilities always sort first, regardless of the random tie-break.
    auto rng = Random(7);
    HexWFCCell a, b;
    a.reset(3);
    b.reset(4);
    foreach (_; 0 .. 1000)
        assert(a.entropyKey(rng) < b.entropyKey(rng));
    // Ties are perturbed.
    HexWFCCell c;
    c.reset(3);
    bool differs = false;
    immutable k = a.entropyKey(rng);
    foreach (_; 0 .. 20)
        if (c.entropyKey(rng) != k)
            differs = true;
    assert(differs);
}
