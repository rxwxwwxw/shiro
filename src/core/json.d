// Minimal JSON tokenizer: a flat token tree over a borrowed source buffer, with object / array
// lookups and string unescaping. Used for glTF headers (View) and story data (Model). Parsing is a
// cold path (it grows one malloc'd token buffer); lookups are @nogc and allocation-free.
module core.json;

import core.stdc.stdlib : free, realloc, strtod;

enum JsonKind : ubyte {
    object,
    array,
    string,
    primitive
}

struct JsonTok {
    JsonKind kind;
    /// Source range; for strings the characters between the quotes.
    int start, end;
    /// Child count (key + value each count for objects).
    int size;
    /// Index of the first token after this token's subtree.
    int next;
}

/// Flat token tree over a borrowed source buffer.
struct Json {
    private const(char)[] src;
    private JsonTok* toks;
    private int count, cap;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(toks);
    }

    /// Tokenizes `text`; false on malformed input or out of memory. Strings are not unescaped.
    bool parse(const(char)[] text) @nogc nothrow @trusted {
        src = text;
        count = 0;
        size_t pos = 0;
        return value(pos, 0) >= 0 && count > 0;
    }

    private int push(JsonKind k, int start) @nogc nothrow @trusted {
        if (count == cap) {
            immutable ncap = cap ? cap * 2 : 1024;
            auto p = cast(JsonTok*)realloc(toks, ncap * JsonTok.sizeof);
            if (p is null)
                return -1;
            toks = p;
            cap = ncap;
        }
        toks[count] = JsonTok(k, start, start, 0, count + 1);
        return count++;
    }

    private void skipWs(ref size_t p) const @nogc nothrow pure @safe {
        while (p < src.length && (src[p] == ' ' || src[p] == '\n' || src[p] == '\r' || src[p] == '\t'))
            p++;
    }

    /// Parses one value at `p`; returns its token index or -1.
    private int value(ref size_t p, int depth) @nogc nothrow @trusted {
        if (depth > 32)
            return -1;
        skipWs(p);
        if (p >= src.length)
            return -1;
        immutable c = src[p];
        if (c == '{' || c == '[') {
            immutable obj = c == '{';
            immutable close = obj ? '}' : ']';
            immutable t = push(obj ? JsonKind.object : JsonKind.array, cast(int)p);
            if (t < 0)
                return -1;
            p++;
            int n = 0;
            skipWs(p);
            if (p < src.length && src[p] == close)
                p++;
            else
                while (true) {
                    if (obj) {
                        skipWs(p);
                        if (p >= src.length || src[p] != '"' || value(p, depth + 1) < 0)
                            return -1;
                        skipWs(p);
                        if (p >= src.length || src[p] != ':')
                            return -1;
                        p++;
                        n++;
                    }
                    if (value(p, depth + 1) < 0)
                        return -1;
                    n++;
                    skipWs(p);
                    if (p >= src.length)
                        return -1;
                    if (src[p] == ',') {
                        p++;
                        continue;
                    }
                    if (src[p] != close)
                        return -1;
                    p++;
                    break;
                }
            toks[t].size = n;
            toks[t].end = cast(int)p;
            toks[t].next = count;
            return t;
        }
        if (c == '"') {
            immutable start = p + 1;
            p++;
            while (p < src.length && src[p] != '"')
                p += src[p] == '\\' ? 2 : 1;
            if (p >= src.length)
                return -1;
            immutable t = push(JsonKind.string, cast(int)start);
            if (t < 0)
                return -1;
            toks[t].end = cast(int)p;
            p++;
            return t;
        }
        immutable start = p;
        while (p < src.length && src[p] != ',' && src[p] != '}' && src[p] != ']' && src[p] != ' '
                && src[p] != '\n' && src[p] != '\r' && src[p] != '\t')
            p++;
        if (p == start)
            return -1;
        immutable t = push(JsonKind.primitive, cast(int)start);
        if (t < 0)
            return -1;
        toks[t].end = cast(int)p;
        return t;
    }

    ref const(JsonTok) tok(int t) const @nogc nothrow @trusted {
        assert(t >= 0 && t < count);
        return toks[t];
    }

    /// Value token of `key` in object `obj`, or -1.
    int get(int obj, const(char)[] key) const @nogc nothrow @trusted {
        if (obj < 0 || toks[obj].kind != JsonKind.object)
            return -1;
        int i = obj + 1;
        foreach (_; 0 .. toks[obj].size / 2) {
            immutable v = i + 1;
            if (src[toks[i].start .. toks[i].end] == key)
                return v;
            i = toks[v].next;
        }
        return -1;
    }

    /// Element `index` of array `arr`, or -1.
    int at(int arr, int index) const @nogc nothrow @trusted {
        if (arr < 0 || toks[arr].kind != JsonKind.array || index < 0 || index >= toks[arr].size)
            return -1;
        int i = arr + 1;
        foreach (_; 0 .. index)
            i = toks[i].next;
        return i;
    }

    int length(int t) const @nogc nothrow @trusted {
        if (t < 0)
            return 0;
        return toks[t].kind == JsonKind.array ? toks[t].size : (toks[t].kind == JsonKind.object ? toks[t].size / 2 : 0);
    }

    const(char)[] str(int t) const @nogc nothrow @trusted {
        return t < 0 ? null : src[toks[t].start .. toks[t].end];
    }

    double num(int t, double fallback = 0) const @nogc nothrow @trusted {
        if (t < 0 || toks[t].kind != JsonKind.primitive)
            return fallback;
        return strtod(src.ptr + toks[t].start, null);
    }

    int integer(int t, int fallback = 0) const @nogc nothrow @trusted {
        return cast(int)num(t, fallback);
    }

    /// `true` / `false` primitives; anything else gives `fallback`.
    bool boolean(int t, bool fallback = false) const @nogc nothrow @trusted {
        if (t < 0 || toks[t].kind != JsonKind.primitive)
            return fallback;
        const s = src[toks[t].start .. toks[t].end];
        return s == "true" ? true : (s == "false" ? false : fallback);
    }

    bool isString(int t) const @nogc nothrow @trusted {
        return t >= 0 && toks[t].kind == JsonKind.string;
    }

    /// Writes string token `t` with escapes resolved (\uXXXX, surrogate pairs included, as UTF-8)
    /// into `dst`; returns the byte count, or -1 if it is not a string, is malformed or does not
    /// fit. The result is never longer than the quoted source.
    ptrdiff_t unescape(int t, char[] dst) const @nogc nothrow @trusted {
        if (!isString(t))
            return -1;
        const s = src[toks[t].start .. toks[t].end];
        size_t o = 0;
        bool put(uint c) {
            char[4] b;
            size_t n;
            if (c < 0x80) {
                b[0] = cast(char)c;
                n = 1;
            } else if (c < 0x800) {
                b[0] = cast(char)(0xC0 | c >> 6);
                b[1] = cast(char)(0x80 | (c & 0x3F));
                n = 2;
            } else if (c < 0x10000) {
                b[0] = cast(char)(0xE0 | c >> 12);
                b[1] = cast(char)(0x80 | (c >> 6 & 0x3F));
                b[2] = cast(char)(0x80 | (c & 0x3F));
                n = 3;
            } else {
                b[0] = cast(char)(0xF0 | c >> 18);
                b[1] = cast(char)(0x80 | (c >> 12 & 0x3F));
                b[2] = cast(char)(0x80 | (c >> 6 & 0x3F));
                b[3] = cast(char)(0x80 | (c & 0x3F));
                n = 4;
            }
            if (o + n > dst.length)
                return false;
            dst[o .. o + n] = b[0 .. n];
            o += n;
            return true;
        }

        int hex4(size_t at) {
            if (at + 4 > s.length)
                return -1;
            int v = 0;
            foreach (ch; s[at .. at + 4]) {
                immutable d = ch >= '0' && ch <= '9' ? ch - '0' : (ch >= 'a' && ch <= 'f'
                        ? ch - 'a' + 10 : (ch >= 'A' && ch <= 'F' ? ch - 'A' + 10 : -1));
                if (d < 0)
                    return -1;
                v = v * 16 + d;
            }
            return v;
        }

        size_t i = 0;
        while (i < s.length) {
            if (s[i] != '\\') {
                if (o == dst.length)
                    return -1;
                dst[o++] = s[i++];
                continue;
            }
            if (i + 1 >= s.length)
                return -1;
            immutable e = s[i + 1];
            i += 2;
            uint c;
            switch (e) {
            case 'n':
                c = '\n';
                break;
            case 't':
                c = '\t';
                break;
            case 'r':
                c = '\r';
                break;
            case 'b':
                c = '\b';
                break;
            case 'f':
                c = '\f';
                break;
            case '"', '\\', '/':
                c = e;
                break;
            case 'u':
                immutable hi = hex4(i);
                if (hi < 0)
                    return -1;
                i += 4;
                c = hi;
                if (hi >= 0xD800 && hi < 0xDC00) {
                    if (i + 1 >= s.length || s[i] != '\\' || s[i + 1] != 'u')
                        return -1;
                    immutable lo = hex4(i + 2);
                    if (lo < 0xDC00 || lo >= 0xE000)
                        return -1;
                    i += 6;
                    c = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                }
                break;
            default:
                return -1;
            }
            if (!put(c))
                return -1;
        }
        return o;
    }
}

unittest {
    Json j;
    assert(j.parse(`{"a":[1, 2.5, {"b":"hi"}], "c": {}, "d": true}`));
    immutable a = j.get(0, "a");
    assert(a >= 0 && j.length(a) == 3);
    assert(j.num(j.at(a, 1)) == 2.5);
    assert(j.str(j.get(j.at(a, 2), "b")) == "hi");
    assert(j.length(j.get(0, "c")) == 0);
    assert(j.get(0, "d") >= 0 && j.get(0, "missing") == -1);
    assert(j.integer(j.at(a, 0)) == 1);
    Json bad;
    assert(!bad.parse(`{"a":[1,}`));
    assert(!bad.parse(`{"a" 1}`));
}

unittest {
    Json j;
    assert(j.parse(`{"t":true, "f":false, "n":3, "s":"a\"b\\c\nàạ😀", "v":"Bà"}`));
    assert(j.boolean(j.get(0, "t")) && !j.boolean(j.get(0, "f"), true));
    assert(j.boolean(j.get(0, "n"), true) && !j.isString(j.get(0, "n")));
    char[64] buf;
    immutable n = j.unescape(j.get(0, "s"), buf[]);
    assert(n > 0 && buf[0 .. n] == "a\"b\\c\nàạ😀");
    // Raw UTF-8 passes through untouched.
    immutable m = j.unescape(j.get(0, "v"), buf[]);
    assert(m > 0 && buf[0 .. m] == "Bà");
    assert(j.unescape(j.get(0, "s"), buf[0 .. 4]) == -1);
    assert(j.unescape(j.get(0, "n"), buf[]) == -1);
}
