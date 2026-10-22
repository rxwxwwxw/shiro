// Uniform bucket grid over world units for creep range queries: rebuilt from scratch every tick
// with a counting sort (two passes, no per-item allocation), queried by circle. Headless Model.
module td.spatial;

import core.stdc.stdlib : calloc, malloc, free;
import core.stdc.string : memset;

struct SpatialGrid {
    /// Bucket edge in world units (about four cells).
    enum int bucketSize = 4096;

    private int bw, bh;
    private uint* start; // bw * bh + 1 prefix offsets
    private ushort* items;
    private size_t capItems;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(start);
        free(items);
    }

    /// Sizes the grid for a world of `width` x `height` units holding up to `maxItems` items.
    void setup(int width, int height, size_t maxItems) @nogc nothrow @trusted {
        free(start);
        free(items);
        bw = width / bucketSize + 1;
        bh = height / bucketSize + 1;
        start = cast(uint*)calloc(cast(size_t)bw * bh + 1, uint.sizeof);
        items = cast(ushort*)malloc(maxItems * ushort.sizeof + 1);
        capItems = maxItems;
        assert(start !is null && items !is null, "spatial grid allocation failed");
    }

    private int bucketOf(int x, int y) const @nogc nothrow pure @safe {
        int bx = x / bucketSize, by = y / bucketSize;
        bx = bx < 0 ? 0 : (bx >= bw ? bw - 1 : bx);
        by = by < 0 ? 0 : (by >= bh ? bh - 1 : by);
        return by * bw + bx;
    }

    /// Re-buckets every live item of `pool` (anything with int x, y and bool alive). Item ids are
    /// pool indices.
    void rebuild(T)(const(T)[] pool) @nogc nothrow @trusted {
        assert(pool.length <= capItems && pool.length <= ushort.max);
        immutable nb = cast(size_t)bw * bh;
        memset(start, 0, (nb + 1) * uint.sizeof);
        foreach (ref it; pool)
            if (it.alive)
                start[bucketOf(it.x, it.y) + 1]++;
        foreach (b; 0 .. nb)
            start[b + 1] += start[b];
        // Fill using start[b] as a cursor, then shift back so start[b] is the bucket's first item.
        foreach (i, ref it; pool)
            if (it.alive)
                items[start[bucketOf(it.x, it.y)]++] = cast(ushort)i;
        for (size_t b = nb; b > 0; b--)
            start[b] = start[b - 1];
        start[0] = 0;
    }

    /// Writes the ids of live items within `r` of (x, y) into `out_` (in bucket order) and returns
    /// how many; stops when `out_` is full.
    size_t query(T)(const(T)[] pool, int x, int y, int r, ushort[] out_) const @nogc nothrow @trusted {
        immutable long r2 = cast(long)r * r;
        int bx0 = (x - r) / bucketSize, bx1 = (x + r) / bucketSize;
        int by0 = (y - r) / bucketSize, by1 = (y + r) / bucketSize;
        bx0 = bx0 < 0 ? 0 : bx0;
        by0 = by0 < 0 ? 0 : by0;
        bx1 = bx1 >= bw ? bw - 1 : bx1;
        by1 = by1 >= bh ? bh - 1 : by1;
        size_t n = 0;
        foreach (by; by0 .. by1 + 1)
            foreach (bx; bx0 .. bx1 + 1) {
                immutable b = by * bw + bx;
                foreach (k; start[b] .. start[b + 1]) {
                    immutable id = items[k];
                    const it = &pool[id];
                    // Items can die after the rebuild (earlier in the same tick).
                    if (!it.alive)
                        continue;
                    immutable long dx = it.x - x, dy = it.y - y;
                    if (dx * dx + dy * dy > r2)
                        continue;
                    if (n == out_.length)
                        return n;
                    out_[n++] = id;
                }
            }
        return n;
    }
}

version (unittest) {
    private struct Dot {
        int x, y;
        bool alive;
    }
}

@nogc nothrow unittest {
    import td.defs : mix;

    // Matches brute force for random dots and circles, including ones at and past the edges.
    Dot[500] dots;
    foreach (i, ref d; dots) {
        d.x = cast(int)(mix(cast(uint)i, 1) % 40_000);
        d.y = cast(int)(mix(cast(uint)i, 2) % 25_000);
        d.alive = mix(cast(uint)i, 3) % 5 != 0;
    }
    SpatialGrid g;
    g.setup(40_000, 25_000, dots.length);
    g.rebuild(dots[]);
    ushort[500] got;
    foreach (q; 0 .. 200) {
        immutable x = cast(int)(mix(q, 4) % 46_000) - 3000, y = cast(int)(mix(q, 5) % 31_000) - 3000;
        immutable r = cast(int)(mix(q, 6) % 9000);
        immutable n = g.query(dots[], x, y, r, got[]);
        size_t expect = 0;
        foreach (i, ref d; dots)
            if (d.alive && (cast(long)(d.x - x)) ^^ 2 + (cast(long)(d.y - y)) ^^ 2 <= cast(long)r * r) {
                expect++;
                bool found = false;
                foreach (k; 0 .. n)
                    found |= got[k] == i;
                assert(found);
            }
        assert(n == expect);
    }
    // A full output buffer stops the query without overrunning it.
    assert(g.query(dots[], 20_000, 12_000, 50_000, got[0 .. 7]) == 7);
}
