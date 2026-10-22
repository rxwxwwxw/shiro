// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro tower defense engine.
// Port of src/SeededRandom.js: Mulberry32 deterministic 32-bit PRNG.
module core.random;

struct Random
{
    private uint _state;
    private uint _seed;

    this(uint seed) @nogc nothrow pure @safe
    {
        setSeed(seed);
    }

    void setSeed(uint seed) @nogc nothrow pure @safe
    {
        _seed = seed;
        _state = seed;
    }

    uint seed() const @nogc nothrow pure @safe
    {
        return _seed;
    }

    /// Next raw 32-bit value (Mulberry32).
    uint next() @nogc nothrow pure @safe
    {
        _state += 0x6D2B79F5u;
        uint t = (_state ^ (_state >>> 15)) * (1u | _state);
        t = (t + (t ^ (t >>> 7)) * (61u | t)) ^ t;
        return t ^ (t >>> 14);
    }

    /// Uniform double in [0, 1).
    double uniform01() @nogc nothrow pure @safe
    {
        return next() / 4294967296.0;
    }

    alias random = uniform01;

    /// Uniform integer in [0, n). n must be > 0.
    uint below(uint n) @nogc nothrow pure @safe
    {
        assert(n > 0);
        return cast(uint)(uniform01() * n);
    }

    /// In-place Fisher-Yates shuffle.
    void shuffle(T)(T[] arr) @nogc nothrow pure @safe
    {
        for (size_t i = arr.length; i > 1; i--)
        {
            immutable j = below(cast(uint) i);
            immutable tmp = arr[i - 1];
            arr[i - 1] = arr[j];
            arr[j] = tmp;
        }
    }
}

@nogc nothrow pure @safe unittest
{
    // Reference values from the JS Mulberry32 implementation, seed = 1.
    auto r = Random(1);
    assert(r.next() == 2693262067u);
    assert(r.next() == 11749833u);
    assert(r.next() == 2265367787u);
    auto a = Random(12345);
    auto b = Random(12345);
    foreach (_; 0 .. 1000)
        assert(a.next() == b.next());
}

@nogc nothrow pure @safe unittest
{
    auto a = Random(1);
    auto b = Random(2);
    bool differs = false;
    foreach (_; 0 .. 8)
        if (a.next() != b.next())
            differs = true;
    assert(differs);
}

@nogc nothrow pure @safe unittest
{
    auto r = Random(99);
    double sum = 0;
    foreach (_; 0 .. 10_000)
    {
        immutable v = r.uniform01();
        assert(v >= 0.0 && v < 1.0);
        sum += v;
    }
    assert(sum / 10_000 > 0.45 && sum / 10_000 < 0.55);
    foreach (_; 0 .. 1000)
        assert(r.below(7) < 7);
}

@nogc nothrow pure @safe unittest
{
    int[10] a = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    int[10] b = a;
    auto r1 = Random(5);
    auto r2 = Random(5);
    r1.shuffle(a[]);
    r2.shuffle(b[]);
    assert(a == b);
    int sum = 0;
    bool moved = false;
    foreach (i, v; a)
    {
        sum += v;
        if (v != cast(int) i)
            moved = true;
    }
    assert(sum == 45 && moved);
}
