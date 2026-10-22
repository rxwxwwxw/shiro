// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro tower defense engine.
// Fixed-capacity bitset used for WFC possibility masks (BitSet!1024 = 128 bytes).
module core.bitset;

import core.bitop : bsf, popcnt;

struct BitSet(size_t N) {
    enum size_t numWords = (N + 63) / 64;
    enum size_t capacity = N;

    ulong[numWords] words;

    void set(size_t bit) @nogc nothrow pure @safe {
        assert(bit < N);
        words[bit >> 6] |= (1UL << (bit & 63));
    }

    void clear(size_t bit) @nogc nothrow pure @safe {
        assert(bit < N);
        words[bit >> 6] &= ~(1UL << (bit & 63));
    }

    bool test(size_t bit) const @nogc nothrow pure @safe {
        assert(bit < N);
        return (words[bit >> 6] & (1UL << (bit & 63))) != 0;
    }

    void reset() @nogc nothrow pure @safe {
        words[] = 0;
    }

    /// Sets bits [0, n).
    void setFirst(size_t n) @nogc nothrow pure @safe {
        assert(n <= N);
        reset();
        foreach (i; 0 .. n >> 6)
            words[i] = ulong.max;
        if (n & 63)
            words[n >> 6] = (1UL << (n & 63)) - 1;
    }

    void intersect(const ref BitSet rhs) @nogc nothrow pure @safe {
        foreach (i; 0 .. numWords)
            words[i] &= rhs.words[i];
    }

    void unite(const ref BitSet rhs) @nogc nothrow pure @safe {
        foreach (i; 0 .. numWords)
            words[i] |= rhs.words[i];
    }

    void subtract(const ref BitSet rhs) @nogc nothrow pure @safe {
        foreach (i; 0 .. numWords)
            words[i] &= ~rhs.words[i];
    }

    bool intersects(const ref BitSet rhs) const @nogc nothrow pure @safe {
        foreach (i; 0 .. numWords)
            if (words[i] & rhs.words[i])
                return true;
        return false;
    }

    bool any() const @nogc nothrow pure @safe {
        foreach (w; words)
            if (w)
                return true;
        return false;
    }

    bool empty() const @nogc nothrow pure @safe {
        return !any();
    }

    size_t count() const @nogc nothrow pure @safe {
        size_t n = 0;
        foreach (w; words)
            n += popcnt(w);
        return n;
    }

    /// Index of the lowest set bit, or size_t.max if empty.
    size_t firstSet() const @nogc nothrow pure @trusted {
        foreach (i, w; words)
            if (w)
                return i * 64 + bsf(w);
        return size_t.max;
    }

    /// Index of the n-th (0-based) set bit, or size_t.max if fewer than n+1 bits are set.
    size_t nthSet(size_t n) const @nogc nothrow pure @trusted {
        foreach (i, word; words) {
            ulong w = word;
            immutable c = popcnt(w);
            if (n >= c) {
                n -= c;
                continue;
            }
            while (n--)
                w &= w - 1;
            return i * 64 + bsf(w);
        }
        return size_t.max;
    }

    bool opEquals(const ref BitSet rhs) const @nogc nothrow pure @safe {
        return words == rhs.words;
    }

    /// Range over set bit indices, ascending.
    auto bits() const @nogc nothrow pure @safe {
        static struct Range {
            const(ulong)[] ws;
            size_t wi;
            ulong cur;

            this(const(ulong)[] w) @nogc nothrow pure @trusted {
                ws = w;
                wi = 0;
                cur = w.length ? w[0] : 0;
                skip();
            }

            private void skip() @nogc nothrow pure @safe {
                while (cur == 0 && wi + 1 < ws.length)
                    cur = ws[++wi];
            }

            bool empty() const @nogc nothrow pure @safe {
                return cur == 0;
            }

            size_t front() const @nogc nothrow pure @trusted {
                return wi * 64 + bsf(cur);
            }

            void popFront() @nogc nothrow pure @safe {
                cur &= cur - 1;
                skip();
            }
        }

        return Range(words[]);
    }
}

alias BitSet1024 = BitSet!1024;

@nogc nothrow pure @safe unittest {
    static assert(BitSet1024.sizeof == 128);
    BitSet1024 b;
    assert(b.empty && b.count == 0 && b.firstSet == size_t.max);
    b.set(0);
    b.set(63);
    b.set(64);
    b.set(923);
    assert(b.test(0) && b.test(63) && b.test(64) && b.test(923));
    assert(!b.test(1) && !b.test(65));
    assert(b.count == 4);
    assert(b.firstSet == 0);
    b.clear(0);
    assert(!b.test(0) && b.count == 3 && b.firstSet == 63);
}

@nogc nothrow pure @safe unittest {
    BitSet1024 a, b;
    a.set(3);
    a.set(100);
    a.set(900);
    b.set(100);
    b.set(900);
    b.set(5);
    assert(a.intersects(b));
    auto c = a;
    c.intersect(b);
    assert(c.count == 2 && c.test(100) && c.test(900));
    c = a;
    c.unite(b);
    assert(c.count == 4);
    c = a;
    c.subtract(b);
    assert(c.count == 1 && c.test(3));
    BitSet1024 d;
    d.set(7);
    assert(!a.intersects(d));
    assert(a == a && !(a == b));
}

@nogc nothrow pure @safe unittest {
    BitSet1024 b;
    foreach (n; [0, 1, 63, 64, 65, 200, 924, 1024]) {
        b.setFirst(n);
        assert(b.count == n);
        if (n > 0)
            assert(b.test(n - 1));
        if (n < 1024)
            assert(!b.test(n));
    }
}

@nogc nothrow pure @safe unittest {
    BitSet!100 b; // non-multiple-of-64 capacity
    static assert(b.numWords == 2);
    immutable size_t[5] want = [2, 40, 64, 77, 99];
    foreach (i; want)
        b.set(i);
    size_t k = 0;
    foreach (i; b.bits) {
        assert(i == want[k]);
        assert(b.nthSet(k) == i);
        k++;
    }
    assert(k == want.length);
    assert(b.nthSet(5) == size_t.max);
    BitSet!100 e;
    foreach (i; e.bits)
        assert(false);
}
