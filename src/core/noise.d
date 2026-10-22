// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro tower defense engine.
// In-house 2D simplex noise (Gustavson), seeded permutation table, @nogc nothrow.
module core.noise;

import core.random : Random;

struct SimplexNoise
{
    private ubyte[512] perm;

    this(uint seed) @nogc nothrow pure @safe
    {
        reseed(seed);
    }

    void reseed(uint seed) @nogc nothrow pure @safe
    {
        ubyte[256] p;
        foreach (i; 0 .. 256)
            p[i] = cast(ubyte) i;
        auto rng = Random(seed);
        rng.shuffle(p[]);
        foreach (i; 0 .. 512)
            perm[i] = p[i & 255];
    }

    private static immutable float[2][8] grad = [
        [1, 1], [-1, 1], [1, -1], [-1, -1], [1, 0], [-1, 0], [0, 1], [0, -1]
    ];

    private static int fastFloor(float x) @nogc nothrow pure @safe
    {
        immutable i = cast(int) x;
        return x < i ? i - 1 : i;
    }

    /// 2D simplex noise in approximately [-1, 1].
    float noise(float x, float y) const @nogc nothrow pure @safe
    {
        enum float F2 = 0.36602540378f; // 0.5 * (sqrt(3) - 1)
        enum float G2 = 0.21132486540f; // (3 - sqrt(3)) / 6

        immutable s = (x + y) * F2;
        immutable i = fastFloor(x + s);
        immutable j = fastFloor(y + s);
        immutable t = (i + j) * G2;
        immutable x0 = x - (i - t);
        immutable y0 = y - (j - t);

        immutable i1 = x0 > y0 ? 1 : 0;
        immutable j1 = 1 - i1;
        immutable x1 = x0 - i1 + G2;
        immutable y1 = y0 - j1 + G2;
        immutable x2 = x0 - 1.0f + 2.0f * G2;
        immutable y2 = y0 - 1.0f + 2.0f * G2;

        immutable ii = i & 255;
        immutable jj = j & 255;

        float corner(float cx, float cy, int gi)
        {
            float t0 = 0.5f - cx * cx - cy * cy;
            if (t0 < 0)
                return 0;
            t0 *= t0;
            immutable g = grad[gi & 7];
            return t0 * t0 * (g[0] * cx + g[1] * cy);
        }

        immutable n0 = corner(x0, y0, perm[ii + perm[jj]]);
        immutable n1 = corner(x1, y1, perm[ii + i1 + perm[jj + j1]]);
        immutable n2 = corner(x2, y2, perm[ii + 1 + perm[jj + 1]]);
        return 70.0f * (n0 + n1 + n2);
    }

    /// Multi-octave (fBm) noise normalized to approximately [-1, 1].
    float fbm(float x, float y, int octaves, float lacunarity = 2.0f, float gain = 0.5f) const @nogc nothrow pure @safe
    {
        float sum = 0, amp = 1, freq = 1, norm = 0;
        foreach (o; 0 .. octaves)
        {
            sum += amp * noise(x * freq, y * freq);
            norm += amp;
            amp *= gain;
            freq *= lacunarity;
        }
        return norm > 0 ? sum / norm : 0;
    }
}

@nogc nothrow pure @safe unittest
{
    auto a = SimplexNoise(7);
    auto b = SimplexNoise(7);
    foreach (i; 0 .. 100)
        assert(a.noise(i * 0.37f, i * 0.91f) == b.noise(i * 0.37f, i * 0.91f));
}

@nogc nothrow pure @safe unittest
{
    auto n = SimplexNoise(42);
    float lo = 1e9f, hi = -1e9f;
    foreach (i; 0 .. 200)
        foreach (j; 0 .. 200)
        {
            immutable v = n.noise(i * 0.13f, j * 0.17f);
            if (v < lo)
                lo = v;
            if (v > hi)
                hi = v;
        }
    assert(lo >= -1.01f && hi <= 1.01f);
    assert(hi - lo > 1.0f); // actually varies
    assert(n.noise(0, 0) == 0); // simplex noise is 0 at the origin lattice point
}

@nogc nothrow pure @safe unittest
{
    // Continuity: tiny step => tiny change.
    auto n = SimplexNoise(3);
    foreach (i; 0 .. 100)
    {
        immutable x = i * 0.31f, y = i * 0.17f;
        immutable d = n.noise(x, y) - n.noise(x + 0.001f, y);
        assert(d < 0.05f && d > -0.05f);
    }
    // Different seeds differ.
    auto m = SimplexNoise(4);
    bool differs = false;
    foreach (i; 1 .. 50)
        if (n.noise(i * 0.4f, i * 0.2f) != m.noise(i * 0.4f, i * 0.2f))
            differs = true;
    assert(differs);
}

@nogc nothrow pure @safe unittest
{
    auto n = SimplexNoise(11);
    foreach (i; 0 .. 100)
    {
        immutable v = n.fbm(i * 0.21f, i * 0.33f, 4);
        assert(v >= -1.01f && v <= 1.01f);
    }
}
