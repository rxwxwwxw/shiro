// Cold-path storage for the story system: a growable malloc'd array and a chunked text arena whose
// slices never move (records keep slices into it for the program's lifetime). Model layer: no SDL,
// @nogc nothrow, no GC.
module story.pool;

import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy;

/// Growable malloc'd array. Elements are moved bit-wise on growth, so do not store pointers into
/// it across a `push`.
struct Pool(T) {
    private T* ptr;
    private uint length_, cap;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(ptr);
    }

    uint length() const @nogc nothrow pure @safe {
        return length_;
    }

    bool push(T v) @nogc nothrow @trusted {
        if (length_ == cap && !reserve(cap ? cap * 2 : 16))
            return false;
        ptr[length_++] = v;
        return true;
    }

    /// Makes room for at least `n` elements; false when out of memory.
    bool reserve(uint n) @nogc nothrow @trusted {
        if (n <= cap)
            return true;
        auto p = cast(T*)realloc(ptr, n * T.sizeof);
        if (p is null)
            return false;
        ptr = p;
        cap = n;
        return true;
    }

    /// Drops elements past `n` (n <= length).
    void shrink(uint n) @nogc nothrow @safe {
        assert(n <= length_);
        length_ = n;
    }

    ref inout(T) opIndex(size_t i) inout return @nogc nothrow @trusted {
        assert(i < length_);
        return ptr[i];
    }

    inout(T)[] slice() inout return @nogc nothrow @trusted {
        return ptr is null ? null : ptr[0 .. length_];
    }

    void clear() @nogc nothrow @safe {
        length_ = 0;
    }
}

@nogc nothrow @safe unittest {
    Pool!int p;
    foreach (i; 0 .. 100)
        assert(p.push(i));
    assert(p.length == 100 && p[99] == 99 && p.slice[50] == 50);
    p.shrink(10);
    assert(p.slice.length == 10);
    p.clear();
    assert(p.length == 0 && p.slice.length == 0);
}

/// Append-only text storage in fixed chunks: a returned slice stays valid until `clear` or
/// destruction, however much is added after it.
struct TextArena {
    private enum size_t chunkSize = 16 * 1024;
    private Pool!(char*) chunks;
    private size_t used = chunkSize;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        foreach (c; chunks.slice)
            free(c);
    }

    /// A copy of `s` (null for an empty string or when out of memory; check `ok`).
    const(char)[] copy(const(char)[] s) @nogc nothrow @trusted {
        auto d = alloc(s.length);
        if (d is null)
            return null;
        memcpy(d.ptr, s.ptr, s.length);
        return d;
    }

    /// Uninitialised room for `n` chars, or null when `n` is 0 or memory runs out.
    char[] alloc(size_t n) @nogc nothrow @trusted {
        if (n == 0)
            return null;
        if (n > chunkSize / 4) {
            // Big strings get a chunk of their own, slotted in before the current one.
            auto big = cast(char*)malloc(n);
            if (big is null || !chunks.push(big)) {
                free(big);
                return null;
            }
            immutable k = chunks.length - 1;
            if (k > 0) {
                auto t = chunks[k];
                chunks[k] = chunks[k - 1];
                chunks[k - 1] = t;
            }
            return big[0 .. n];
        }
        if (used + n > chunkSize) {
            auto c = cast(char*)malloc(chunkSize);
            if (c is null || !chunks.push(c)) {
                free(c);
                return null;
            }
            used = 0;
        }
        auto d = chunks[chunks.length - 1][used .. used + n];
        used += n;
        return d;
    }

    void clear() @nogc nothrow @trusted {
        foreach (c; chunks.slice)
            free(c);
        chunks.clear();
        used = chunkSize;
    }
}

@nogc nothrow @safe unittest {
    TextArena a;
    auto x = a.copy("hello");
    char[6000] big = 'z';
    auto y = a.copy(big[]);
    foreach (i; 0 .. 5000)
        a.copy("filler text");
    auto z = a.copy("after");
    assert(x == "hello" && y.length == 6000 && y[5999] == 'z' && z == "after");
    assert(a.copy("") is null);
}
