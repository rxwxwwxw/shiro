// Story values: nil, booleans, IEEE doubles and strings. Constant strings point into the compiled
// program; strings built at run time (concatenation) live in the StoryState's text heap and are
// addressed by offset so the heap may grow or compact. Model layer: no SDL, @nogc nothrow.
//
// Lists and maps are references to collections owned by the StoryState.
//
// Coercions (the same everywhere, so story authors only learn one rule):
//   nil behaves as 0 / false / "" ; booleans as 0 / 1 ; strings are true when non-empty;
//   collections are always true (use len()) and 0 as numbers.
module story.value;

import core.stdc.stdio : snprintf;

enum ValueKind : ubyte {
    nil,
    boolean,
    number,
    /// `ptr[0 .. len]`, owned by the program.
    text,
    /// `heap[off .. off + len]` in the owning StoryState.
    heapText,
    /// Collection `off` in the owning StoryState (reference semantics: copies share it).
    list,
    map,
    /// `:name`: symbol `off` interned in the owning StoryState. Symbols equal only themselves.
    symbol
}

struct Value {
    ValueKind kind;
    uint len;
    union {
        bool b;
        double n;
        const(char)* ptr;
        size_t off;
    }

    static Value number(double v) @nogc nothrow pure @trusted {
        Value r;
        r.kind = ValueKind.number;
        r.n = v;
        return r;
    }

    static Value boolean(bool v) @nogc nothrow pure @trusted {
        Value r;
        r.kind = ValueKind.boolean;
        r.b = v;
        return r;
    }

    /// A constant string; `s` must outlive every copy of the value.
    static Value constText(const(char)[] s) @nogc nothrow pure @trusted {
        Value r;
        r.kind = ValueKind.text;
        r.ptr = s.ptr;
        r.len = cast(uint)s.length;
        return r;
    }

    bool isNil() const @nogc nothrow pure @safe {
        return kind == ValueKind.nil;
    }

    bool isText() const @nogc nothrow pure @safe {
        return kind == ValueKind.text || kind == ValueKind.heapText;
    }

    bool isCollection() const @nogc nothrow pure @safe {
        return kind == ValueKind.list || kind == ValueKind.map;
    }

    bool isSymbol() const @nogc nothrow pure @safe {
        return kind == ValueKind.symbol;
    }
}

static assert(Value.sizeof == 16);

/// Numeric view of a value (strings and collections are 0).
double toNumber(const Value v) @nogc nothrow pure @trusted {
    final switch (v.kind) {
    case ValueKind.nil:
        return 0;
    case ValueKind.boolean:
        return v.b ? 1 : 0;
    case ValueKind.number:
        return v.n;
    case ValueKind.text:
    case ValueKind.heapText:
    case ValueKind.list:
    case ValueKind.map:
    case ValueKind.symbol:
        return 0;
    }
}

bool truthy(const Value v) @nogc nothrow pure @trusted {
    final switch (v.kind) {
    case ValueKind.nil:
        return false;
    case ValueKind.boolean:
        return v.b;
    case ValueKind.number:
        return v.n != 0 && v.n == v.n;
    case ValueKind.text:
    case ValueKind.heapText:
        return v.len > 0;
    case ValueKind.list:
    case ValueKind.map:
        // A collection is a reference; test emptiness with len().
        return true;
    case ValueKind.symbol:
        return true;
    }
}

/// Saturating conversion to int (NaN is 0), for the integer views game code uses.
int toInt(double d) @nogc nothrow pure @safe {
    if (d != d)
        return 0;
    if (d >= int.max)
        return int.max;
    if (d <= int.min)
        return int.min;
    return cast(int)d;
}

/// Exact integer view for game data: true and `out` set when `v` is a whole number in int range
/// (booleans count as 0 / 1, nil as 0); false for fractions, NaN, strings and collections.
bool toIntExact(const Value v, out int r) @nogc nothrow pure @trusted {
    if (v.kind == ValueKind.nil)
        return true;
    if (v.kind == ValueKind.boolean) {
        r = v.b;
        return true;
    }
    if (v.kind != ValueKind.number || v.n != v.n || v.n < int.min || v.n > int.max)
        return false;
    r = cast(int)v.n;
    return r == v.n;
}

@nogc nothrow pure @safe unittest {
    int r;
    assert(toIntExact(Value.number(42), r) && r == 42);
    assert(toIntExact(Value.number(-7), r) && r == -7);
    assert(toIntExact(Value.init, r) && r == 0 && toIntExact(Value.boolean(true), r) && r == 1);
    assert(!toIntExact(Value.number(2.5), r) && !toIntExact(Value.number(1e10), r));
    assert(!toIntExact(Value.number(double.nan), r) && !toIntExact(Value.constText("3"), r));
}

@nogc nothrow pure @safe unittest {
    assert(toNumber(Value.init) == 0 && !truthy(Value.init));
    assert(toNumber(Value.boolean(true)) == 1 && truthy(Value.boolean(true)));
    assert(truthy(Value.number(-0.5)) && !truthy(Value.number(0)) && !truthy(Value.number(double.nan)));
    assert(truthy(Value.constText("a")) && !truthy(Value.constText("")));
    assert(toInt(1e300) == int.max && toInt(-1e300) == int.min && toInt(3.9) == 3 && toInt(-3.9) == -3);
}

/// Writes `d` for display into `buf`: integers without a decimal point, other values with up to
/// six significant digits. Returns the written slice (truncated to `buf`).
char[] formatNumber(double d, char[] buf) @nogc nothrow @trusted {
    if (buf.length == 0)
        return buf;
    int n;
    if (d == d && d > -1e15 && d < 1e15 && d == cast(double)cast(long)d)
        n = snprintf(buf.ptr, buf.length, "%lld", cast(long)d);
    else
        n = snprintf(buf.ptr, buf.length, "%g", d);
    if (n < 0)
        n = 0;
    return buf[0 .. n < buf.length ? n : buf.length - 1];
}

@nogc nothrow @safe unittest {
    char[32] b;
    assert(formatNumber(42, b[]) == "42" && formatNumber(-7, b[]) == "-7");
    assert(formatNumber(2.5, b[]) == "2.5" && formatNumber(1.0 / 3, b[]) == "0.333333");
    assert(formatNumber(0, b[]) == "0" && formatNumber(-0.0, b[]) == "0");
    char[3] tiny;
    assert(formatNumber(12345, tiny[]) == "12");
}

/// Deterministic rounding helpers (exact IEEE operations; no libm transcendental calls).
double floorOf(double d) @nogc nothrow pure @safe {
    if (d != d || d >= 4503599627370496.0 || d <= -4503599627370496.0)
        return d;
    immutable t = cast(double)cast(long)d;
    return t > d ? t - 1 : t;
}

double ceilOf(double d) @nogc nothrow pure @safe {
    return -floorOf(-d);
}

/// Half away from zero, like most people round.
double roundOf(double d) @nogc nothrow pure @safe {
    return d < 0 ? -floorOf(-d + 0.5) : floorOf(d + 0.5);
}

/// Floored modulo (the result takes the sign of `b`), NaN when `b` is 0.
double modOf(double a, double b) @nogc nothrow pure @safe {
    if (b == 0)
        return double.nan;
    return a - b * floorOf(a / b);
}

@nogc nothrow pure @safe unittest {
    assert(floorOf(2.7) == 2 && floorOf(-2.2) == -3 && floorOf(-2) == -2);
    assert(ceilOf(2.1) == 3 && ceilOf(-2.7) == -2);
    assert(roundOf(2.5) == 3 && roundOf(-2.5) == -3 && roundOf(2.49) == 2);
    assert(modOf(7, 3) == 1 && modOf(-7, 3) == 2 && modOf(7, -3) == -2);
    immutable z = modOf(1, 0);
    assert(z != z);
    // Bit-exact results the save/replay hash depends on.
    assert((0.1 + 0.2) * 10 == 3.0000000000000004);
}
