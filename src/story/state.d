// Story state: every named variable the story reads or writes, including the flattened fields of
// characters and records ("elder.bond.trust" is one slot). Names are interned once (cold, at story
// load); play reads and writes by id. Slots may carry bounds that clamp numeric writes, which is
// how bounded qualities (affection 0..100) stay in range. Strings built at run time live in a text
// heap compacted at statement boundaries. Model layer: no SDL, @nogc nothrow.
module story.state;

import core.random : Random;
import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy;
import story.pool;
import story.value;

/// Longest variable name, dotted path included.
enum int maxStoryNameLen = 127;

private struct SlotInfo {
    const(char)[] name;
    double lo = -double.infinity, hi = double.infinity;
}

struct StoryState {
    private Pool!SlotInfo info;
    private Pool!Value values;
    private TextArena names;
    private char* heap;
    private size_t heapLen, heapCap;
    /// Story dice (`rand`); reseeded by `reset`.
    Random rng;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(heap);
    }

    /// Id of `name`, adding it (value nil) when new; -1 when the name is empty, too long or memory
    /// runs out.
    int intern(const(char)[] name) @nogc nothrow @trusted {
        immutable f = find(name);
        if (f >= 0)
            return f;
        if (name.length == 0 || name.length > maxStoryNameLen)
            return -1;
        auto copy = names.copy(name);
        if (copy is null || !info.reserve(info.length + 1) || !values.reserve(values.length + 1))
            return -1;
        info.push(SlotInfo(copy));
        values.push(Value.init);
        return info.length - 1;
    }

    /// Id of `name`, or -1.
    int find(const(char)[] name) const @nogc nothrow @safe {
        foreach (i, ref s; info.slice)
            if (s.name == name)
                return cast(int)i;
        return -1;
    }

    const(char)[] name(int id) const return @nogc nothrow @safe {
        assert(id >= 0 && id < length);
        return info.slice[id].name;
    }

    int length() const @nogc nothrow pure @safe {
        return cast(int)info.length;
    }

    /// Clamps numeric writes to `id` into lo..hi from now on.
    void setBounds(int id, double lo, double hi) @nogc nothrow @trusted {
        assert(id >= 0 && id < length && lo <= hi);
        info[id].lo = lo;
        info[id].hi = hi;
    }

    bool bounded(int id) const @nogc nothrow @safe {
        return id >= 0 && id < length && (info.slice[id].lo > -double.infinity || info.slice[id].hi < double.infinity);
    }

    Value value(int id) const @nogc nothrow @safe {
        return id >= 0 && id < length ? values.slice[id] : Value.init;
    }

    void setValue(int id, Value v) @nogc nothrow @trusted {
        assert(id >= 0 && id < length);
        if (v.kind == ValueKind.number) {
            const s = &info[id];
            if (v.n < s.lo)
                v.n = s.lo;
            else if (v.n > s.hi)
                v.n = s.hi;
        }
        values[id] = v;
    }

    /// Integer view (saturating; nil and strings are 0, booleans 0 / 1).
    int get(int id) const @nogc nothrow @safe {
        return toInt(toNumber(value(id)));
    }

    bool flag(int id) const @nogc nothrow @safe {
        return truthy(value(id));
    }

    void set(int id, int v) @nogc nothrow @safe {
        setValue(id, Value.number(v));
    }

    void add(int id, int d) @nogc nothrow @safe {
        setValue(id, Value.number(toNumber(value(id)) + d));
    }

    /// Integer value by name (0 when the name was never interned); for cold-path readers.
    int named(const(char)[] n) const @nogc nothrow @safe {
        return get(find(n));
    }

    /// The characters of a string value (null for other kinds).
    const(char)[] text(const Value v) const return @nogc nothrow @trusted {
        if (v.kind == ValueKind.text)
            return v.ptr[0 .. v.len];
        if (v.kind == ValueKind.heapText) {
            assert(v.off + v.len <= heapLen);
            return heap[v.off .. v.off + v.len];
        }
        return null;
    }

    /// A run-time string holding `parts` joined; nil when memory runs out.
    Value makeText(scope const(char)[][] parts...) @nogc nothrow @trusted {
        size_t n = 0;
        foreach (p; parts)
            n += p.length;
        if (n == 0)
            return Value.constText("");
        if (heapLen + n > heapCap) {
            auto cap = heapCap ? heapCap : 4096;
            while (cap < heapLen + n)
                cap *= 2;
            // Parts may be slices of the heap itself; grow into a new block so they stay valid
            // until copied.
            auto h = cast(char*)malloc(cap);
            if (h is null)
                return Value.init;
            if (heapLen)
                memcpy(h, heap, heapLen);
            auto old = heap;
            heap = h;
            heapCap = cap;
            scope (exit)
                free(old);
            return appendText(n, parts);
        }
        return appendText(n, parts);
    }

    private Value appendText(size_t n, scope const(char)[][] parts) @nogc nothrow @trusted {
        Value r;
        r.kind = ValueKind.heapText;
        r.off = heapLen;
        r.len = cast(uint)n;
        foreach (p; parts) {
            memcpy(heap + heapLen, p.ptr, p.length);
            heapLen += p.length;
        }
        return r;
    }

    /// Bytes of run-time strings, live or not.
    size_t heapUsed() const @nogc nothrow pure @safe {
        return heapLen;
    }

    /// Compacts the text heap down to the strings variables still hold. Call only where no
    /// heap value lives outside the state (between statements).
    void collect() @nogc nothrow @trusted {
        if (heapLen == 0)
            return;
        size_t live = 0;
        foreach (ref v; values.slice)
            if (v.kind == ValueKind.heapText)
                live += v.len;
        auto fresh = cast(char*)malloc(live ? live * 2 : 4096);
        if (fresh is null)
            return;
        size_t at = 0;
        foreach (ref v; values.slice)
            if (v.kind == ValueKind.heapText) {
                memcpy(fresh + at, heap + v.off, v.len);
                v.off = at;
                at += v.len;
            }
        free(heap);
        heap = fresh;
        heapLen = at;
        heapCap = live ? live * 2 : 4096;
    }

    /// Clears every value to nil and reseeds the dice; names and bounds stay (a new playthrough on
    /// the same story; run the program's initializer afterwards for declared starting values).
    void reset(uint seed = 0) @nogc nothrow @trusted {
        foreach (ref v; values.slice)
            v = Value.init;
        heapLen = 0;
        rng.setSeed(seed);
    }

    /// FNV-1a over every name and value (string contents, not addresses), for determinism checks.
    ulong hash() const @nogc nothrow @trusted {
        ulong h = 0xcbf29ce484222325UL;
        void mix(uint b) {
            h = (h ^ b) * 0x100000001b3UL;
        }

        foreach (i, ref s; info.slice) {
            foreach (c; s.name)
                mix(c);
            const v = values.slice[i];
            mix(v.kind == ValueKind.heapText ? ValueKind.text : v.kind);
            if (v.kind == ValueKind.number) {
                ulong bits = *cast(const(ulong)*)&v.n;
                foreach (k; 0 .. 8)
                    mix(cast(uint)(bits >> (k * 8)) & 0xFF);
            } else if (v.kind == ValueKind.boolean)
                mix(v.b);
            else
                foreach (c; text(v))
                    mix(c);
        }
        return h;
    }
}

@nogc nothrow @safe unittest {
    StoryState s;
    immutable a = s.intern("met_elder"), b = s.intern("gold_bonus");
    assert(a == 0 && b == 1 && s.intern("met_elder") == a && s.length == 2);
    assert(!s.flag(a) && s.get(-1) == 0 && s.value(a).isNil);
    immutable h0 = s.hash();
    s.set(a, 1);
    s.add(b, 50);
    s.add(b, -20);
    assert(s.flag(a) && s.get(b) == 30 && s.named("gold_bonus") == 30 && s.named("nope") == 0);
    assert(s.hash() != h0 && s.name(b) == "gold_bonus");
    assert(s.intern("") == -1);
    char[maxStoryNameLen + 1] long_ = 'x';
    assert(s.intern(long_[]) == -1 && s.intern(long_[0 .. $ - 1]) == 2);
    s.reset();
    assert(s.length == 3 && s.value(b).isNil);
}

@nogc nothrow @safe unittest {
    // Bounds clamp numeric writes; other kinds pass through.
    StoryState s;
    immutable t = s.intern("elder.bond.trust");
    s.setBounds(t, 0, 100);
    s.set(t, 150);
    assert(s.get(t) == 100 && s.bounded(t));
    s.add(t, -500);
    assert(s.get(t) == 0);
    s.setValue(t, Value.number(42.5));
    assert(s.value(t).n == 42.5);
    s.setValue(t, Value.boolean(true));
    assert(s.flag(t));
}

@nogc nothrow @safe unittest {
    // Run-time strings survive heap growth and compaction; dead ones are dropped.
    StoryState s;
    immutable a = s.intern("a"), b = s.intern("b");
    s.setValue(a, s.makeText("hello", " ", "world"));
    foreach (i; 0 .. 2000)
        s.setValue(b, s.makeText("garbage garbage ", s.text(s.value(a))));
    assert(s.text(s.value(a)) == "hello world" && s.heapUsed > 4096);
    immutable h = s.hash();
    s.collect();
    assert(s.heapUsed == 11 + 27 && s.text(s.value(a)) == "hello world");
    assert(s.text(s.value(b)) == "garbage garbage hello world" && s.hash() == h);
    // Constant and heap strings with equal text hash alike.
    StoryState c;
    c.intern("a");
    c.intern("b");
    c.setValue(0, Value.constText("hello world"));
    c.setValue(1, c.makeText("garbage garbage hello world"));
    assert(c.hash() == h);
}
