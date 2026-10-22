// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro engine.
//
// Microbenchmark: raw BitSet!1024 throughput in the shapes the solver's hot loop uses
// (intersect / unite / subtract / popcount / bit iteration) plus the full per-edge
// "allowed states across a direction" computation.
module benchmarks.bench_propagation;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import core.bitset;
import core.random : Random;
import wfc.hex;
import wfc.rules;

__gshared AdjacencyRules rules;
__gshared ulong sink;

private double secondsSince(MonoTime t0) {
    return (MonoTime.currTime - t0).total!"nsecs" * 1e-9;
}

int main() {
    AdjacencyRules.build(rules);
    auto rng = Random(1);

    enum size_t n = 1024;
    static __gshared BitSet1024[n] a, b;
    foreach (i; 0 .. n)
        foreach (w; 0 .. 16) {
            a[i].words[w] = rng.next() | (cast(ulong)rng.next() << 32);
            b[i].words[w] = rng.next() | (cast(ulong)rng.next() << 32);
        }

    printf("%-28s %12s %12s\n", "operation".ptr, "Mops/s".ptr, "ns/op".ptr);

    enum size_t iters = 20_000_000;
    {
        immutable t0 = MonoTime.currTime;
        foreach (i; 0 .. iters)
            a[i & (n - 1)].intersect(b[(i * 7) & (n - 1)]);
        immutable s = secondsSince(t0);
        sink += a[3].words[1];
        printf("%-28s %12.1f %12.2f\n", "intersect (128 B)".ptr, iters / s / 1e6, s / iters * 1e9);
    }
    {
        immutable t0 = MonoTime.currTime;
        foreach (i; 0 .. iters)
            a[i & (n - 1)].unite(b[(i * 7) & (n - 1)]);
        immutable s = secondsSince(t0);
        sink += a[3].words[1];
        printf("%-28s %12.1f %12.2f\n", "unite (128 B)".ptr, iters / s / 1e6, s / iters * 1e9);
    }
    {
        immutable t0 = MonoTime.currTime;
        foreach (i; 0 .. iters)
            a[i & (n - 1)].subtract(b[(i * 7) & (n - 1)]);
        immutable s = secondsSince(t0);
        sink += a[3].words[1];
        printf("%-28s %12.1f %12.2f\n", "subtract (128 B)".ptr, iters / s / 1e6, s / iters * 1e9);
    }
    {
        immutable t0 = MonoTime.currTime;
        size_t acc = 0;
        foreach (i; 0 .. iters)
            acc += a[i & (n - 1)].count;
        immutable s = secondsSince(t0);
        sink += acc;
        printf("%-28s %12.1f %12.2f\n", "count / popcnt (128 B)".ptr, iters / s / 1e6, s / iters * 1e9);
    }
    {
        enum size_t it = 2_000_000;
        immutable t0 = MonoTime.currTime;
        size_t acc = 0;
        foreach (i; 0 .. it)
            foreach (bit; a[i & (n - 1)].bits)
                acc += bit;
        immutable s = secondsSince(t0);
        sink += acc;
        printf("%-28s %12.2f %12.2f\n", "iterate set bits (~512)".ptr, it / s / 1e6, s / it * 1e9);
    }
    {
        // The solver's real unit of work: all states of a cell -> allowed set in a neighbor.
        BitSet1024 full;
        full.setFirst(numStates);
        BitSet1024 half = full;
        foreach (i; 0 .. numStates)
            if (i & 1)
                half.clear(i);
        enum size_t it = 200_000;
        immutable t0 = MonoTime.currTime;
        size_t acc = 0;
        foreach (i; 0 .. it) {
            auto r = rules.allowedAcross((i & 1) ? half : full, cast(HexDir)(i % 6));
            acc += r.words[0];
        }
        immutable s = secondsSince(t0);
        sink += acc;
        printf("%-28s %12.3f %12.1f\n", "allowedAcross (full cell)".ptr, it / s / 1e6, s / it * 1e9);
    }
    printf("(sink %llu)\n", sink);
    return 0;
}
