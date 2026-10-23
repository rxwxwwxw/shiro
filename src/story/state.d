// Story state: named flags and integer variables set by dialogue choices and events, read by
// conditions and by the tower defense link. Names are interned once (cold, at story load); play
// reads and writes by id. Model layer: no SDL, @nogc nothrow throughout.
module story.state;

/// Interned names (flags and variables share one table; a flag is a variable that is non-zero).
enum int maxStoryVars = 128;
enum int maxStoryNameLen = 31;

struct StoryState {
    private char[maxStoryNameLen][maxStoryVars] names;
    private ubyte[maxStoryVars] nameLen;
    private int[maxStoryVars] values;
    private int count;

    /// Id of `name`, adding it (value 0) when new; -1 when the name is empty, too long or the
    /// table is full.
    int intern(const(char)[] name) @nogc nothrow @safe {
        immutable f = find(name);
        if (f >= 0)
            return f;
        if (name.length == 0 || name.length > maxStoryNameLen || count == maxStoryVars)
            return -1;
        names[count][0 .. name.length] = name[];
        nameLen[count] = cast(ubyte)name.length;
        values[count] = 0;
        return count++;
    }

    /// Id of `name`, or -1.
    int find(const(char)[] name) const @nogc nothrow @safe {
        foreach (i; 0 .. count)
            if (names[i][0 .. nameLen[i]] == name)
                return i;
        return -1;
    }

    const(char)[] name(int id) const return @nogc nothrow @safe {
        assert(id >= 0 && id < count);
        return names[id][0 .. nameLen[id]];
    }

    int length() const @nogc nothrow pure @safe {
        return count;
    }

    int get(int id) const @nogc nothrow @safe {
        return id >= 0 && id < count ? values[id] : 0;
    }

    bool flag(int id) const @nogc nothrow @safe {
        return get(id) != 0;
    }

    void set(int id, int v) @nogc nothrow @safe {
        assert(id >= 0 && id < count);
        values[id] = v;
    }

    void add(int id, int d) @nogc nothrow @safe {
        assert(id >= 0 && id < count);
        values[id] += d;
    }

    /// Value by name (0 when the name was never interned); for cold-path readers like the TD link.
    int named(const(char)[] n) const @nogc nothrow @safe {
        return get(find(n));
    }

    /// Clears every value; names stay interned (a new playthrough on the same story).
    void reset() @nogc nothrow @safe {
        values[0 .. count] = 0;
    }

    /// FNV-1a over every name and value, for determinism checks.
    ulong hash() const @nogc nothrow @safe {
        ulong h = 0xcbf29ce484222325UL;
        void mix(uint b) {
            h = (h ^ b) * 0x100000001b3UL;
        }

        foreach (i; 0 .. count) {
            foreach (c; names[i][0 .. nameLen[i]])
                mix(c);
            foreach (k; 0 .. 4)
                mix((values[i] >> (k * 8)) & 0xFF);
        }
        return h;
    }
}

@nogc nothrow @safe unittest {
    StoryState s;
    immutable a = s.intern("met_elder"), b = s.intern("gold_bonus");
    assert(a == 0 && b == 1 && s.intern("met_elder") == a && s.length == 2);
    assert(!s.flag(a) && s.get(-1) == 0);
    immutable h0 = s.hash();
    s.set(a, 1);
    s.add(b, 50);
    s.add(b, -20);
    assert(s.flag(a) && s.get(b) == 30 && s.named("gold_bonus") == 30 && s.named("nope") == 0);
    assert(s.hash() != h0 && s.name(b) == "gold_bonus");
    assert(s.intern("") == -1 && s.intern("this_name_is_far_too_long_to_be_interned") == -1);
    s.reset();
    assert(s.hash() == h0 && s.length == 2);
}

@nogc nothrow @safe unittest {
    StoryState s;
    char[4] n = "v000";
    foreach (i; 0 .. maxStoryVars) {
        n[1] = cast(char)('0' + i / 100);
        n[2] = cast(char)('0' + i / 10 % 10);
        n[3] = cast(char)('0' + i % 10);
        assert(s.intern(n[]) == i);
    }
    assert(s.intern("overflow") == -1 && s.find("v127") == 127);
}
