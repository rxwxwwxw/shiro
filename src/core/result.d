// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// D port for the Shiro tower defense engine.
// Zero-allocation tagged union for expected operational failures (no exceptions).
module core.result;

enum EngineError : int {
    None = 0,
    InvalidHexCoordinates,
    MapSeedExhausted,
    BufferOverflow,
    ResourceNotFound,
    InitializationFailed,
    PlacementFailed,
    RoutingFailed
}

struct Result(T, E = EngineError) {
    private union {
        T _value;
        E _error;
    }

    private bool _isOk;

    static Result ok(T val) @nogc nothrow {
        Result r;
        r._isOk = true;
        r._value = val;
        return r;
    }

    static Result err(E e) @nogc nothrow {
        Result r;
        r._isOk = false;
        r._error = e;
        return r;
    }

    bool isOk() const @nogc nothrow pure @safe {
        return _isOk;
    }

    bool isErr() const @nogc nothrow pure @safe {
        return !_isOk;
    }

    inout(T) value() inout @nogc nothrow @trusted {
        assert(_isOk);
        return _value;
    }

    inout(E) error() inout @nogc nothrow @trusted {
        assert(!_isOk);
        return _error;
    }

    inout(T) valueOr(inout(T) fallback) inout @nogc nothrow @trusted {
        return _isOk ? _value : fallback;
    }
}

@nogc nothrow unittest {
    auto a = Result!int.ok(42);
    assert(a.isOk && !a.isErr);
    assert(a.value == 42);
    assert(a.valueOr(7) == 42);

    auto b = Result!int.err(EngineError.BufferOverflow);
    assert(!b.isOk && b.isErr);
    assert(b.error == EngineError.BufferOverflow);
    assert(b.valueOr(7) == 7);
}

@nogc nothrow unittest {
    enum Custom : ubyte {
        A,
        B
    }

    struct P {
        int x, y;
    }

    auto r = Result!(P, Custom).ok(P(1, 2));
    assert(r.value.x == 1 && r.value.y == 2);
    auto e = Result!(P, Custom).err(Custom.B);
    assert(e.error == Custom.B);
}
