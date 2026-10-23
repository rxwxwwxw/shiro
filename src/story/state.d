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

/// A list, or a map with insertion-ordered string keys. Malloc'd, owned by the StoryState.
private struct Coll {
    Value* vals;
    /// Map keys (strings), parallel to `vals`; null for lists.
    Value* keys;
    uint len, cap;
    bool isMap, live, marked;
    /// Read-only (`data` declarations): writes fail.
    bool frozen;
}

/// Most elements one collection holds.
enum uint maxCollectionLen = 1 << 20;

struct StoryState {
    private Pool!SlotInfo info;
    private Pool!Coll colls;
    private Pool!uint freeColls;
    private uint newColls;
    private Pool!Value values;
    private TextArena names;
    /// Symbol names by id (`:name`); kept by `reset`, like variable names.
    private Pool!(const(char)[]) symbols;
    private char* heap;
    private size_t heapLen, heapCap;
    /// Story dice (`rand`); reseeded by `reset`.
    Random rng;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(heap);
        foreach (ref c; colls.slice)
            freeColl(c);
    }

    private static void freeColl(ref Coll c) @nogc nothrow @trusted {
        free(c.vals);
        free(c.keys);
        c = Coll.init;
    }

    // ---- collections -----------------------------------------------------------------------

    /// A new empty list or map (nil when memory runs out).
    Value newCollection(bool isMap) @nogc nothrow @trusted {
        uint id;
        if (freeColls.length) {
            id = freeColls[freeColls.length - 1];
            freeColls.shrink(freeColls.length - 1);
        } else {
            if (!colls.push(Coll.init))
                return Value.init;
            id = colls.length - 1;
        }
        colls[id] = Coll.init;
        colls[id].live = true;
        colls[id].isMap = isMap;
        newColls++;
        Value v;
        v.kind = isMap ? ValueKind.map : ValueKind.list;
        v.off = id;
        return v;
    }

    private inout(Coll)* coll(const Value c) inout return @nogc nothrow @trusted {
        if (!c.isCollection || c.off >= colls.length || !colls.slice[c.off].live)
            return null;
        return &colls.slice[c.off];
    }

    /// Elements of a list or map (values), empty for anything else.
    const(Value)[] items(const Value c) const return @nogc nothrow @trusted {
        auto k = coll(c);
        return k is null || k.vals is null ? null : k.vals[0 .. k.len];
    }

    /// Keys of a map, in insertion order.
    const(Value)[] keys(const Value c) const return @nogc nothrow @trusted {
        auto k = coll(c);
        return k is null || k.keys is null ? null : k.keys[0 .. k.len];
    }

    /// Element count of a collection (0 otherwise).
    uint count(const Value c) const @nogc nothrow @safe {
        auto k = coll(c);
        return k is null ? 0 : k.len;
    }

    private bool grow(ref Coll k) @nogc nothrow @trusted {
        if (k.len < k.cap)
            return true;
        if (k.cap >= maxCollectionLen)
            return false;
        immutable n = k.cap ? k.cap * 2 : 4;
        auto v = cast(Value*)realloc(k.vals, n * Value.sizeof);
        if (v is null)
            return false;
        k.vals = v;
        if (k.isMap) {
            auto ks = cast(Value*)realloc(k.keys, n * Value.sizeof);
            if (ks is null)
                return false;
            k.keys = ks;
        }
        k.cap = n;
        return true;
    }

    /// Makes `c` and every collection reachable from it read-only.
    void freeze(Value c) @nogc nothrow @trusted {
        auto k = coll(c);
        if (k is null || k.frozen)
            return;
        k.frozen = true;
        foreach (i; 0 .. k.len)
            freeze(k.vals[i]);
    }

    bool frozen(const Value c) const @nogc nothrow @safe {
        auto k = coll(c);
        return k !is null && k.frozen;
    }

    /// Appends to a list; false when `list` is not one or memory runs out.
    bool append(Value list, Value v) @nogc nothrow @trusted {
        auto k = coll(list);
        if (k is null || k.isMap || k.frozen || !grow(*k))
            return false;
        k.vals[k.len++] = v;
        return true;
    }

    /// Index of `key` in a map, or -1.
    private int keyIndex(ref const Coll k, const(char)[] key) const @nogc nothrow @trusted {
        foreach (i; 0 .. k.len)
            if (text(k.keys[i]) == key)
                return cast(int)i;
        return -1;
    }

    /// A map key's characters: a string, or a symbol's name (`m[:damage]` is `m["damage"]`).
    const(char)[] keyText(const Value key) const return @nogc nothrow @safe {
        return key.isSymbol ? symbolName(key) : text(key);
    }

    private static bool keyLike(const Value key) @nogc nothrow pure @safe {
        return key.isText || key.isSymbol;
    }

    /// `c[key]`: list index (number, negative counts from the end) or map key (string or
    /// symbol); nil when absent.
    Value at(const Value c, const Value key) const @nogc nothrow @trusted {
        auto k = coll(c);
        if (k is null)
            return Value.init;
        if (k.isMap) {
            immutable i = keyLike(key) ? keyIndex(*k, keyText(key)) : -1;
            return i < 0 ? Value.init : k.vals[i];
        }
        immutable i = listIndex(*k, key);
        return i < 0 ? Value.init : k.vals[i];
    }

    private static long listIndex(ref const Coll k, const Value key) @nogc nothrow @safe {
        if (key.kind != ValueKind.number || key.n != key.n)
            return -1;
        long i = cast(long)key.n;
        if (i < 0)
            i += k.len;
        return i >= 0 && i < k.len ? i : -1;
    }

    /// `c[key] = v`; a new map key is added, a list index must exist. False when it cannot.
    bool put(Value c, Value key, Value v) @nogc nothrow @trusted {
        auto k = coll(c);
        if (k is null || k.frozen)
            return false;
        if (!k.isMap) {
            immutable i = listIndex(*k, key);
            if (i < 0)
                return false;
            k.vals[i] = v;
            return true;
        }
        if (!keyLike(key))
            return false;
        immutable i = keyIndex(*k, keyText(key));
        if (i >= 0) {
            k.vals[i] = v;
            return true;
        }
        if (!grow(*k))
            return false;
        // Keys are strings; a symbol key is stored by name.
        k.keys[k.len] = key.isSymbol ? Value.constText(symbolName(key)) : key;
        k.vals[k.len++] = v;
        return true;
    }

    /// Removes list index or map key `key`; false when absent.
    bool remove(Value c, Value key) @nogc nothrow @trusted {
        auto k = coll(c);
        if (k is null || k.frozen)
            return false;
        long i = k.isMap ? (keyLike(key) ? keyIndex(*k, keyText(key)) : -1) : listIndex(*k, key);
        if (i < 0)
            return false;
        foreach (j; cast(uint)i + 1 .. k.len) {
            k.vals[j - 1] = k.vals[j];
            if (k.isMap)
                k.keys[j - 1] = k.keys[j];
        }
        k.len--;
        return true;
    }

    /// Collections created since the last `collect`.
    uint collectionsCreated() const @nogc nothrow pure @safe {
        return newColls;
    }

    /// The symbol `:name` (interned on first use); nil when the name is empty or memory runs out.
    Value symbol(const(char)[] name) @nogc nothrow @trusted {
        Value v;
        foreach (i, n; symbols.slice)
            if (n == name) {
                v.kind = ValueKind.symbol;
                v.off = i;
                return v;
            }
        if (name.length == 0 || name.length > maxStoryNameLen)
            return v;
        auto copy = names.copy(name);
        if (copy is null || !symbols.push(copy))
            return v;
        v.kind = ValueKind.symbol;
        v.off = symbols.length - 1;
        return v;
    }

    /// Name of a symbol value (null for other kinds).
    const(char)[] symbolName(const Value v) const return @nogc nothrow @trusted {
        return v.kind == ValueKind.symbol && v.off < symbols.length ? symbols.slice[v.off] : null;
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
        // Mark collections reachable from variables, free the rest.
        foreach (ref c; colls.slice)
            c.marked = false;
        foreach (ref v; values.slice)
            mark(v);
        foreach (i, ref c; colls.slice)
            if (c.live && !c.marked) {
                freeColl(c);
                freeColls.push(cast(uint)i);
            }
        newColls = 0;
        if (heapLen == 0)
            return;
        size_t live = 0;
        foreach (ref v; values.slice)
            if (v.kind == ValueKind.heapText)
                live += v.len;
        foreach (ref c; colls.slice)
            if (c.live)
                foreach (k; 0 .. c.len) {
                    if (c.vals[k].kind == ValueKind.heapText)
                        live += c.vals[k].len;
                    if (c.isMap && c.keys[k].kind == ValueKind.heapText)
                        live += c.keys[k].len;
                }
        auto fresh = cast(char*)malloc(live ? live * 2 : 4096);
        if (fresh is null)
            return;
        size_t at = 0;
        void move(ref Value v) {
            if (v.kind != ValueKind.heapText)
                return;
            memcpy(fresh + at, heap + v.off, v.len);
            v.off = at;
            at += v.len;
        }

        foreach (ref v; values.slice)
            move(v);
        foreach (ref c; colls.slice)
            if (c.live)
                foreach (k; 0 .. c.len) {
                    move(c.vals[k]);
                    if (c.isMap)
                        move(c.keys[k]);
                }
        free(heap);
        heap = fresh;
        heapLen = at;
        heapCap = live ? live * 2 : 4096;
    }

    private void mark(const Value v) @nogc nothrow @trusted {
        if (!v.isCollection || v.off >= colls.length)
            return;
        auto c = &colls[v.off];
        if (!c.live || c.marked)
            return;
        c.marked = true;
        foreach (k; 0 .. c.len)
            mark(c.vals[k]);
    }

    /// Clears every value to nil and reseeds the dice; names and bounds stay (a new playthrough on
    /// the same story; run the program's initializer afterwards for declared starting values).
    void reset(uint seed = 0) @nogc nothrow @trusted {
        foreach (ref v; values.slice)
            v = Value.init;
        heapLen = 0;
        foreach (ref c; colls.slice)
            freeColl(c);
        colls.clear();
        freeColls.clear();
        newColls = 0;
        rng.setSeed(seed);
    }

    private void hashValue(const Value v, ref ulong h, int depth) const @nogc nothrow @trusted {
        void mix(uint b) {
            h = (h ^ b) * 0x100000001b3UL;
        }

        mix(v.kind == ValueKind.heapText ? ValueKind.text : v.kind);
        if (v.kind == ValueKind.number) {
            ulong bits = *cast(const(ulong)*)&v.n;
            foreach (k; 0 .. 8)
                mix(cast(uint)(bits >> (k * 8)) & 0xFF);
        } else if (v.kind == ValueKind.boolean)
            mix(v.b);
        else if (v.kind == ValueKind.symbol) {
            foreach (c; symbolName(v))
                mix(c);
        } else if (v.isCollection) {
            // Contents, not ids; cycles are cut off by depth.
            if (depth > 8)
                return;
            const ks = keys(v);
            foreach (i, ref e; items(v)) {
                if (ks.length)
                    hashValue(ks[i], h, depth + 1);
                hashValue(e, h, depth + 1);
            }
        } else
            foreach (c; text(v))
                mix(c);
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
            hashValue(values.slice[i], h, 0);
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
    // Lists and maps: reference semantics, ordered keys, unreachable ones freed by collect.
    StoryState s;
    immutable a = s.intern("xs"), b = s.intern("m");
    auto xs = s.newCollection(false);
    s.setValue(a, xs);
    assert(s.append(xs, Value.number(1)) && s.append(xs, s.makeText("two")));
    assert(s.count(xs) == 2 && s.at(xs, Value.number(-1)).isText && s.at(xs, Value.number(5)).isNil);
    assert(s.put(xs, Value.number(0), Value.number(9)) && s.at(xs, Value.number(0)).n == 9);
    assert(!s.put(xs, Value.number(7), Value.number(1)));
    auto m = s.newCollection(true);
    s.setValue(b, m);
    assert(s.put(m, Value.constText("z"), Value.number(2)) && s.put(m, Value.constText("a"), xs));
    assert(s.text(s.keys(m)[0]) == "z" && s.at(m, Value.constText("a")).off == xs.off);
    immutable h = s.hash();
    s.newCollection(false); // garbage
    s.collect();
    assert(s.count(xs) == 2 && s.text(s.at(xs, Value.number(1))) == "two" && s.hash() == h);
    assert(s.remove(m, Value.constText("z")) && s.count(m) == 1);
    s.setValue(a, Value.init);
    s.setValue(b, Value.init);
    s.collect();
    assert(s.count(xs) == 0);
}

@nogc nothrow @safe unittest {
    // Symbols intern by name and survive reset; frozen collections refuse writes, deeply.
    StoryState s;
    immutable a = s.symbol("elder"), b = s.symbol("smith");
    assert(a.isSymbol && s.symbol("elder").off == a.off && b.off != a.off);
    assert(s.symbolName(b) == "smith" && s.symbolName(Value.number(1)) is null);
    assert(s.symbol("").isNil);
    auto outer = s.newCollection(true), inner = s.newCollection(false);
    assert(s.put(outer, Value.constText("xs"), inner) && s.append(inner, a));
    s.freeze(outer);
    assert(s.frozen(outer) && s.frozen(inner));
    assert(!s.append(inner, b) && !s.put(outer, Value.constText("y"), b) && !s.remove(inner, Value.number(0)));
    assert(s.count(inner) == 1 && s.symbolName(s.items(inner)[0]) == "elder");
    s.reset();
    assert(s.symbol("smith").off == b.off);
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
